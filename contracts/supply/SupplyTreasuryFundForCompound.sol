// SPDX-License-Identifier: UNLICENSED
/* 

  _                          _   _____   _                       
 | |       ___   _ __     __| | |  ___| | |   __ _   _ __    ___ 
 | |      / _ \ | '_ \   / _` | | |_    | |  / _` | | '__|  / _ \
 | |___  |  __/ | | | | | (_| | |  _|   | | | (_| | | |    |  __/
 |_____|  \___| |_| |_|  \__,_| |_|     |_|  \__,_| |_|     \___|
                                                                 
LendFlare.finance
*/

pragma solidity =0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../common/IBaseReward.sol";

interface ICompoundComptroller {
    /*** Assets You Are In ***/
    function enterMarkets(address[] calldata cTokens)
        external
        returns (uint256[] memory);

    function exitMarket(address cToken) external returns (uint256);

    function getAssetsIn(address account)
        external
        view
        returns (address[] memory);

    function checkMembership(address account, address cToken)
        external
        view
        returns (bool);

    function claimComp(address holder) external;

    function claimComp(address holder, address[] memory cTokens) external;

    function getCompAddress() external view returns (address);

    function getAllMarkets() external view returns (address[] memory);

    function accountAssets(address user)
        external
        view
        returns (address[] memory);

    function markets(address _cToken)
        external
        view
        returns (bool isListed, uint256 collateralFactorMantissa);
}

interface ICompound {
    function borrow(uint256 borrowAmount) external returns (uint256);

    function isCToken(address) external view returns (bool);

    function comptroller() external view returns (ICompoundComptroller);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function getAccountSnapshot(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function accrualBlockNumber() external view returns (uint256);

    function borrowRatePerBlock() external view returns (uint256);

    function borrowBalanceStored(address user) external view returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function decimals() external view returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);

    function exchangeRateCurrent() external returns (uint256);

    function interestRateModel() external view returns (address);
}

interface ICompoundCEther is ICompound {
    function repayBorrow() external payable;

    function mint() external payable;
}

interface ICompoundCErc20 is ICompound {
    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function mint(uint256 mintAmount) external returns (uint256);

    function underlying() external returns (address); // like usdc usdt
}

interface ISupplyRewardFactory {
    function createReward(
        address _rewardToken,
        address _virtualBalance,
        address _owner
    ) external returns (address);
}

contract SupplyTreasuryFundForCompound is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public rewardCompPool;
    address public supplyRewardFactory;
    address public virtualBalance;
    address public compAddress;
    address public compoundComptroller;
    address public underlyToken;
    address public lpToken;
    address public owner;
    uint256 public totalUnderlyToken;
    uint256 public frozenUnderlyToken;
    bool public isErc20;
    bool private initialized;

    modifier onlyOwner() {
        require(msg.sender == owner, "!authorized");
        _;
    }

    constructor(
        address _owner,
        address _lpToken,
        address _compoundComptroller,
        address _supplyRewardFactory
    ) public {
        owner = _owner;
        compoundComptroller = _compoundComptroller;
        lpToken = _lpToken;
        supplyRewardFactory = _supplyRewardFactory;
    }

    // call by Owner (SupplyBooster)
    function initialize(
        address _virtualBalance,
        address _underlyToken,
        bool _isErc20
    ) public onlyOwner {
        require(!initialized, "initialized");

        compAddress = ICompoundComptroller(compoundComptroller).getCompAddress();

        underlyToken = _underlyToken;

        virtualBalance = _virtualBalance;
        isErc20 = _isErc20;

        rewardCompPool = ISupplyRewardFactory(supplyRewardFactory).createReward(
                compAddress,
                virtualBalance,
                address(this)
            );

        initialized = true;
    }

    function _mintEther(uint256 _amount) internal {
        ICompoundCEther(lpToken).mint{value: _amount}();
    }

    function _mintErc20(uint256 _amount) internal {
        ICompoundCErc20(lpToken).mint(_amount);
    }

    receive() external payable {}

    function migrate() external onlyOwner nonReentrant returns (uint256) {
        uint256 cTokens = IERC20(lpToken).balanceOf(address(this));

        ICompound(lpToken).redeem(cTokens);

        uint256 bal;

        if (isErc20) {
            bal = IERC20(underlyToken).balanceOf(address(this));

            IERC20(underlyToken).safeTransfer(owner, bal);
        } else {
            bal = address(this).balance;

            if (bal > 0) {
                payable(owner).transfer(bal);
            }
        }
    }

    function _depositFor(address _for, uint256 _amount) internal {
        require(initialized, "!initialized");
        totalUnderlyToken = totalUnderlyToken.add(_amount);

        if (isErc20) {
            IERC20(underlyToken).safeApprove(lpToken, 0);
            IERC20(underlyToken).safeApprove(lpToken, _amount);

            _mintErc20(_amount);
        } else {
            _mintEther(_amount);
        }

        if (_for != address(0)) {
            IBaseReward(rewardCompPool).stake(_for);
        }
    }

    function depositFor(address _for) public payable onlyOwner nonReentrant {
        _depositFor(_for, msg.value);
    }

    function depositFor(address _for, uint256 _amount)
        public
        onlyOwner
        nonReentrant
    {
        _depositFor(_for, _amount);
    }

    function withdrawFor(address _to, uint256 _amount)
        public
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        require(initialized, "!initialized");

        IBaseReward(rewardCompPool).withdraw(_to);

        require(totalUnderlyToken >= _amount, "!insufficient balance");

        totalUnderlyToken = totalUnderlyToken.sub(_amount);

        ICompound(lpToken).redeemUnderlying(_amount);

        uint256 bal;

        if (isErc20) {
            bal = IERC20(underlyToken).balanceOf(address(this));

            IERC20(underlyToken).safeTransfer(_to, bal);
        } else {
            bal = address(this).balance;

            if (bal > 0) {
                payable(_to).transfer(bal);
            }
        }

        return bal;
    }

    function borrow(
        address _to,
        uint256 _lendingAmount,
        uint256 _lendingInterest
    ) public nonReentrant returns (uint256) {
        require(initialized, "!initialized");

        totalUnderlyToken = totalUnderlyToken.sub(_lendingAmount);
        frozenUnderlyToken = frozenUnderlyToken.add(_lendingAmount);

        ICompound(lpToken).redeemUnderlying(_lendingAmount);

        if (isErc20) {
            IERC20(underlyToken).safeTransfer(
                _to,
                _lendingAmount.sub(_lendingInterest)
            );

            if (_lendingInterest > 0) {
                IERC20(underlyToken).safeTransfer(owner, _lendingInterest);
            }
        } else {
            payable(_to).transfer(_lendingAmount.sub(_lendingInterest));
            if (_lendingInterest > 0) {
                payable(owner).transfer(_lendingInterest);
            }
        }

        return _lendingInterest;
    }

    function repayBorrow() public payable nonReentrant {
        require(initialized, "!initialized");

        _mintEther(msg.value);

        totalUnderlyToken = totalUnderlyToken.add(msg.value);
        frozenUnderlyToken = frozenUnderlyToken.sub(msg.value);
    }

    function repayBorrow(uint256 _lendingAmount) public nonReentrant {
        require(initialized, "!initialized");

        IERC20(underlyToken).safeApprove(lpToken, 0);
        IERC20(underlyToken).safeApprove(lpToken, _lendingAmount);

        _mintErc20(_lendingAmount);

        totalUnderlyToken = totalUnderlyToken.add(_lendingAmount);
        frozenUnderlyToken = frozenUnderlyToken.sub(_lendingAmount);
    }

    function getBalance() public view returns (uint256) {
        uint256 exchangeRateStored = ICompound(lpToken).exchangeRateStored();
        uint256 cTokens = IERC20(lpToken).balanceOf(address(this));

        return exchangeRateStored.mul(cTokens).div(1e18);
    }

    function claim() public onlyOwner nonReentrant returns (uint256) {
        require(initialized, "!initialized");

        ICompoundComptroller(compoundComptroller).claimComp(address(this));

        uint256 balanceOfComp = IERC20(compAddress).balanceOf(address(this));

        if (balanceOfComp > 0) {
            IERC20(compAddress).safeTransfer(rewardCompPool, balanceOfComp);

            IBaseReward(rewardCompPool).notifyRewardAmount(balanceOfComp);
        }

        uint256 bal;
        uint256 cTokens = IERC20(lpToken).balanceOf(address(this));

        // If Uses withdraws all the money, the remaining ctoken is profit.
        if (totalUnderlyToken == 0 && frozenUnderlyToken == 0) {
            if (cTokens > 0) {
                ICompound(lpToken).redeem(cTokens);

                if (isErc20) {
                    bal = IERC20(underlyToken).balanceOf(address(this));

                    IERC20(underlyToken).safeTransfer(owner, bal);
                } else {
                    bal = address(this).balance;

                    if (bal > 0) {
                        payable(owner).transfer(bal);
                    }
                }

                return bal;
            }
        }

        uint256 exchangeRateStored = ICompound(lpToken).exchangeRateCurrent();

        // ctoken price
        uint256 cTokenPrice = cTokens.mul(exchangeRateStored).div(1e18);

        if (cTokenPrice > totalUnderlyToken.add(frozenUnderlyToken)) {
            uint256 interestCToken = cTokenPrice
                .sub(totalUnderlyToken.add(frozenUnderlyToken))
                .mul(1e18)
                .div(exchangeRateStored);

            ICompound(lpToken).redeem(interestCToken);

            if (isErc20) {
                bal = IERC20(underlyToken).balanceOf(address(this));

                IERC20(underlyToken).safeTransfer(owner, bal);
            } else {
                bal = address(this).balance;

                if (bal > 0) {
                    payable(owner).transfer(bal);
                }
            }
        }

        return bal;
    }

    function getReward(address _for) public onlyOwner nonReentrant {
        if (IBaseReward(rewardCompPool).earned(_for) > 0) {
            IBaseReward(rewardCompPool).getReward(_for);
        }
    }

    function getBorrowRatePerBlock() public view returns (uint256) {
        return ICompound(lpToken).borrowRatePerBlock();
    }

    /* function getCollateralFactorMantissa() public view returns (uint256) {
        ICompoundComptroller comptroller = ICompound(lpToken).comptroller();
        (bool isListed, uint256 collateralFactorMantissa) = comptroller.markets(
            lpToken
        );

        return isListed ? collateralFactorMantissa : 800000000000000000;
    } */
}
