// SPDX-License-Identifier: UNLICENSED
/* 

  _                          _   _____   _                       
 | |       ___   _ __     __| | |  ___| | |   __ _   _ __    ___ 
 | |      / _ \ | '_ \   / _` | | |_    | |  / _` | | '__|  / _ \
 | |___  |  __/ | | | | | (_| | |  _|   | | | (_| | | |    |  __/
 |_____|  \___| |_| |_|  \__,_| |_|     |_|  \__,_| |_|     \___|
                                                                 
LendFlare.finance
*/

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./convex/ConvexInterfacesV2.sol";
import "./common/IVirtualBalanceWrapper.sol";

contract ConvexBoosterV2 is Initializable, ReentrancyGuard, IConvexBoosterV2 {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // https://curve.readthedocs.io/registry-address-provider.html
    ICurveAddressProvider public curveAddressProvider;

    address public constant ZERO_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public convexRewardFactory;
    address public virtualBalanceWrapperFactory;
    address public originConvexBooster;
    address public rewardCrvToken;
    address public rewardCvxToken;
    uint256 public version;

    address public lendingMarket;
    address public owner;
    address public governance;

    struct PoolInfo {
        uint256 originConvexPid;
        address curveSwapAddress; /* like 3pool https://github.com/curvefi/curve-js/blob/master/src/constants/abis/abis-ethereum.ts */
        address lpToken;
        address originCrvRewards;
        address originStash;
        address virtualBalance;
        address rewardCrvPool;
        address rewardCvxPool;
        bool shutdown;
    }

    struct ZapInfo {
        address zapAddress;
        address basePoolAddress;
        uint256 nCoins;
        bool isMeta;
        bool isMetaFactory;
    }

    PoolInfo[] public override poolInfo;

    mapping(uint256 => mapping(address => uint256)) public frozenTokens; // pid => (user => amount)
    mapping(address => ZapInfo) public curveZaps; // curveSwapAddress => zap address

    event Deposited(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateExtraRewards(uint256 pid, uint256 index, address extraReward);
    event Initialized(address indexed thisAddress);
    event ToggleShutdownPool(uint256 pid, bool shutdown);
    event SetOwner(address owner);
    event SetGovernance(address governance);
    event CurveZap(address lpToken, address curveZapAddress);

    modifier onlyOwner() {
        require(owner == msg.sender, "ConvexBooster: caller is not the owner");
        _;
    }

    modifier onlyGovernance() {
        require(
            governance == msg.sender,
            "ConvexBooster: caller is not the governance"
        );
        _;
    }

    modifier onlyLendingMarket() {
        require(
            lendingMarket == msg.sender,
            "ConvexBooster: caller is not the lendingMarket"
        );

        _;
    }

    function setOwner(address _owner) public onlyOwner {
        owner = _owner;

        emit SetOwner(_owner);
    }

    /* 
    The default governance user is GenerateLendingPools contract.
    It will be set to DAO in the future 
    */
    function setGovernance(address _governance) public onlyOwner {
        governance = _governance;

        emit SetGovernance(_governance);
    }

    function setLendingMarket(address _v) public onlyOwner {
        require(_v != address(0), "!_v");

        lendingMarket = _v;
    }

    // @custom:oz-upgrades-unsafe-allow constructor
    constructor() public initializer {}

    function initialize(
        address _owner,
        address _originConvexBooster,
        address _convexRewardFactory,
        address _virtualBalanceWrapperFactory,
        address _rewardCrvToken,
        address _rewardCvxToken
    ) public initializer {
        owner = _owner;
        governance = _owner;
        convexRewardFactory = _convexRewardFactory;
        originConvexBooster = _originConvexBooster;
        virtualBalanceWrapperFactory = _virtualBalanceWrapperFactory;
        rewardCrvToken = _rewardCrvToken;
        rewardCvxToken = _rewardCvxToken;
        version = 1;

        curveAddressProvider = ICurveAddressProvider(
            0x0000000022D53366457F9d5E68Ec105046FC4383
        );

        emit Initialized(address(this));
    }

    function _addConvexPool(
        uint256 _originConvexPid,
        address _lpToken,
        address _originCrvRewards,
        address _originStash,
        address _curveSwapAddress
    ) internal {
        address virtualBalance = IVirtualBalanceWrapperFactory(
            virtualBalanceWrapperFactory
        ).createWrapper(address(this));

        address rewardCrvPool = IConvexRewardFactory(convexRewardFactory)
            .createReward(rewardCrvToken, virtualBalance, address(this));

        address rewardCvxPool = IConvexRewardFactory(convexRewardFactory)
            .createReward(rewardCvxToken, virtualBalance, address(this));

        uint256 extraRewardsLength = IOriginConvexRewardPool(_originCrvRewards)
            .extraRewardsLength();

        if (extraRewardsLength > 0) {
            for (uint256 i = 0; i < extraRewardsLength; i++) {
                address extraRewardToken = IOriginConvexRewardPool(
                    _originCrvRewards
                ).extraRewards(i);

                address extraRewardPool = IConvexRewardFactory(
                    convexRewardFactory
                ).createReward(
                        IOriginConvexRewardPool(extraRewardToken).rewardToken(),
                        virtualBalance,
                        address(this)
                    );

                IConvexRewardPool(rewardCrvPool).addExtraReward(
                    extraRewardPool
                );
            }
        }

        poolInfo.push(
            PoolInfo({
                originConvexPid: _originConvexPid,
                curveSwapAddress: _curveSwapAddress,
                lpToken: _lpToken,
                originCrvRewards: _originCrvRewards,
                originStash: _originStash,
                virtualBalance: virtualBalance,
                rewardCrvPool: rewardCrvPool,
                rewardCvxPool: rewardCvxPool,
                shutdown: false
            })
        );
    }

    function addConvexPool(uint256 _originConvexPid)
        public
        override
        onlyGovernance
    {
        (
            address lpToken,
            ,
            ,
            address originCrvRewards,
            address originStash,
            bool shutdown
        ) = IOriginConvexBooster(originConvexBooster).poolInfo(
                _originConvexPid
            );

        require(!shutdown, "!shutdown");
        require(lpToken != address(0), "!lpToken");

        ICurveRegistry registry = ICurveRegistry(
            ICurveAddressProvider(curveAddressProvider).get_registry()
        );

        address curveSwapAddress = registry.get_pool_from_lp_token(lpToken);

        _addConvexPool(
            _originConvexPid,
            lpToken,
            originCrvRewards,
            originStash,
            curveSwapAddress
        );
    }

    // Reference https://curve.readthedocs.io/ref-addresses.html?highlight=zap#deposit-zaps
    function addConvexPool(
        uint256 _originConvexPid,
        address _curveZapAddress,
        address _basePoolAddress,
        uint256 _nCoins,
        bool _isMeta,
        bool _isMetaFactory
    ) public override onlyGovernance {
        require(_curveZapAddress != address(0), "!_curveZapAddress");

        (
            address lpToken,
            ,
            ,
            address originCrvRewards,
            address originStash,
            bool shutdown
        ) = IOriginConvexBooster(originConvexBooster).poolInfo(
                _originConvexPid
            );

        require(!shutdown, "!shutdown");
        require(lpToken != address(0), "!lpToken");

        curveZaps[lpToken] = ZapInfo(
            _curveZapAddress,
            _basePoolAddress,
            _nCoins,
            _isMeta,
            _isMetaFactory
        );

        _addConvexPool(
            _originConvexPid,
            lpToken,
            originCrvRewards,
            originStash,
            _curveZapAddress
        );

        emit CurveZap(lpToken, _curveZapAddress);
    }

    function updateExtraRewards(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];

        (
            ,
            ,
            ,
            address originCrvRewards,
            ,
            bool shutdown
        ) = IOriginConvexBooster(originConvexBooster).poolInfo(
                pool.originConvexPid
            );

        require(!shutdown, "!shutdown");

        uint256 originExtraRewardsLength = IOriginConvexRewardPool(
            originCrvRewards
        ).extraRewardsLength();

        uint256 currentExtraRewardsLength = IConvexRewardPool(
            pool.rewardCrvPool
        ).extraRewardsLength();

        for (
            uint256 i = currentExtraRewardsLength;
            i < originExtraRewardsLength;
            i++
        ) {
            address extraRewardToken = IOriginConvexRewardPool(originCrvRewards)
                .extraRewards(i);

            address extraRewardPool = IConvexRewardFactory(convexRewardFactory)
                .createReward(
                    IOriginConvexRewardPool(extraRewardToken).rewardToken(),
                    pool.virtualBalance,
                    address(this)
                );

            IConvexRewardPool(pool.rewardCrvPool).addExtraReward(
                extraRewardPool
            );

            emit UpdateExtraRewards(_pid, i, extraRewardPool);
        }
    }

    function toggleShutdownPool(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];

        pool.shutdown = !pool.shutdown;

        emit ToggleShutdownPool(_pid, pool.shutdown);
    }

    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) public override onlyLendingMarket nonReentrant returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];

        IERC20(pool.lpToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        /* (
            address lpToken,
            address token,
            address gauge,
            address crvRewards,
            address stash,
            bool shutdown
        ) */
        (, , , , , bool shutdown) = IOriginConvexBooster(originConvexBooster)
            .poolInfo(pool.originConvexPid);

        require(!shutdown, "!convex shutdown");
        require(!pool.shutdown, "!shutdown");

        IERC20(pool.lpToken).safeApprove(originConvexBooster, 0);
        IERC20(pool.lpToken).safeApprove(originConvexBooster, _amount);

        IOriginConvexBooster(originConvexBooster).deposit(
            pool.originConvexPid,
            _amount,
            true
        );

        IConvexRewardPool(pool.rewardCrvPool).stake(_user);
        IConvexRewardPool(pool.rewardCvxPool).stake(_user);

        IVirtualBalanceWrapper(pool.virtualBalance).stakeFor(_user, _amount);

        emit Deposited(_user, _pid, _amount);

        return true;
    }

    function withdrawFrozenTokens(uint256 _pid, uint256 _amount)
        public
        nonReentrant
    {
        require(_amount > 0, "!_amount");

        PoolInfo storage pool = poolInfo[_pid];

        frozenTokens[_pid][msg.sender] = frozenTokens[_pid][msg.sender].sub(
            _amount
        );

        IOriginConvexRewardPool(pool.originCrvRewards).withdrawAndUnwrap(
            _amount,
            true
        );

        IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
    }

    function withdrawFor(
        uint256 _pid,
        uint256 _amount,
        address _user,
        bool _frozenTokens
    ) public override onlyLendingMarket nonReentrant returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];

        if (_frozenTokens) {
            frozenTokens[_pid][_user] = frozenTokens[_pid][_user].add(_amount);
        } else {
            IOriginConvexRewardPool(pool.originCrvRewards).withdrawAndUnwrap(
                _amount,
                true
            );

            IERC20(pool.lpToken).safeTransfer(_user, _amount);
        }

        if (IConvexRewardPool(pool.rewardCrvPool).earned(_user) > 0) {
            IConvexRewardPool(pool.rewardCrvPool).getReward(_user);
        }

        if (IConvexRewardPool(pool.rewardCvxPool).earned(_user) > 0) {
            IConvexRewardPool(pool.rewardCvxPool).getReward(_user);
        }

        IVirtualBalanceWrapper(pool.virtualBalance).withdrawFor(_user, _amount);

        IConvexRewardPool(pool.rewardCrvPool).withdraw(_user);
        IConvexRewardPool(pool.rewardCvxPool).withdraw(_user);

        emit Withdrawn(_user, _pid, _amount);

        return true;
    }

    function _removeLiquidity(
        address _lpToken,
        address _curveSwapAddress,
        uint256 _amount,
        int128 _coinId
    ) internal {
        if (curveZaps[_lpToken].zapAddress != address(0)) {
            _curveSwapAddress = curveZaps[_lpToken].zapAddress;

            if (curveZaps[_lpToken].isMetaFactory) {
                ICurveSwapV2(_curveSwapAddress).remove_liquidity_one_coin(
                    _lpToken,
                    _amount,
                    _coinId,
                    0
                );

                return;
            }
        }

        ICurveSwapV2(_curveSwapAddress).remove_liquidity_one_coin(
            _amount,
            _coinId,
            0
        );
    }

    function liquidate(
        uint256 _pid,
        int128 _coinId,
        address _user,
        uint256 _amount
    )
        external
        override
        onlyLendingMarket
        nonReentrant
        returns (address, uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];

        IOriginConvexRewardPool(pool.originCrvRewards).withdrawAndUnwrap(
            _amount,
            true
        );

        IVirtualBalanceWrapper(pool.virtualBalance).withdrawFor(_user, _amount);

        if (IConvexRewardPool(pool.rewardCrvPool).earned(_user) > 0) {
            IConvexRewardPool(pool.rewardCrvPool).getReward(_user);
        }

        if (IConvexRewardPool(pool.rewardCvxPool).earned(_user) > 0) {
            IConvexRewardPool(pool.rewardCvxPool).getReward(_user);
        }

        IConvexRewardPool(pool.rewardCrvPool).withdraw(_user);
        IConvexRewardPool(pool.rewardCvxPool).withdraw(_user);

        IERC20(pool.lpToken).safeApprove(pool.curveSwapAddress, 0);
        IERC20(pool.lpToken).safeApprove(pool.curveSwapAddress, _amount);

        address curveSwapAddress = pool.curveSwapAddress;
        address underlyToken;

        if (curveZaps[pool.lpToken].zapAddress != address(0)) {
            uint256 nCoins = curveZaps[pool.lpToken].nCoins;
            
            underlyToken = ICurveSwap(curveZaps[pool.lpToken].basePoolAddress)
                .coins(uint256(_coinId).sub(nCoins.sub(1)));
        } else {
            underlyToken = ICurveSwap(pool.curveSwapAddress).coins(
                uint256(_coinId)
            );
        }

        _removeLiquidity(pool.lpToken, curveSwapAddress, _amount, _coinId);

        if (underlyToken == ZERO_ADDRESS) {
            uint256 totalAmount = address(this).balance;

            msg.sender.sendValue(totalAmount);

            return (ZERO_ADDRESS, totalAmount);
        } else {
            uint256 totalAmount = IERC20(underlyToken).balanceOf(address(this));

            IERC20(underlyToken).safeTransfer(msg.sender, totalAmount);

            return (underlyToken, totalAmount);
        }
    }

    function getRewards(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];

        if (IConvexRewardPool(pool.rewardCrvPool).earned(msg.sender) > 0) {
            IConvexRewardPool(pool.rewardCrvPool).getReward(msg.sender);
        }

        if (IConvexRewardPool(pool.rewardCvxPool).earned(msg.sender) > 0) {
            IConvexRewardPool(pool.rewardCvxPool).getReward(msg.sender);
        }
    }

    function claimRewardToken(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];

        IOriginConvexRewardPool(pool.originCrvRewards).getReward(
            address(this),
            true
        );

        address rewardUnderlyToken = IOriginConvexRewardPool(
            pool.originCrvRewards
        ).rewardToken();
        uint256 crvBalance = IERC20(rewardUnderlyToken).balanceOf(
            address(this)
        );

        if (crvBalance > 0) {
            IERC20(rewardUnderlyToken).safeTransfer(
                pool.rewardCrvPool,
                crvBalance
            );

            IConvexRewardPool(pool.rewardCrvPool).notifyRewardAmount(
                crvBalance
            );
        }

        uint256 extraRewardsLength = IConvexRewardPool(pool.rewardCrvPool)
            .extraRewardsLength();

        for (uint256 i = 0; i < extraRewardsLength; i++) {
            address currentExtraReward = IConvexRewardPool(pool.rewardCrvPool)
                .extraRewards(i);
            address originExtraRewardToken = IOriginConvexRewardPool(
                pool.originCrvRewards
            ).extraRewards(i);
            address extraRewardUnderlyToken = IOriginConvexVirtualBalanceRewardPool(
                    originExtraRewardToken
                ).rewardToken();
            IOriginConvexVirtualBalanceRewardPool(originExtraRewardToken)
                .getReward(address(this));
            uint256 extraBalance = IERC20(extraRewardUnderlyToken).balanceOf(
                address(this)
            );
            if (extraBalance > 0) {
                IERC20(extraRewardUnderlyToken).safeTransfer(
                    currentExtraReward,
                    extraBalance
                );
                IConvexRewardPool(currentExtraReward).notifyRewardAmount(
                    extraBalance
                );
            }
        }

        /* cvx */
        uint256 cvxBal = IERC20(rewardCvxToken).balanceOf(address(this));

        if (cvxBal > 0) {
            IERC20(rewardCvxToken).safeTransfer(pool.rewardCvxPool, cvxBal);

            IConvexRewardPool(pool.rewardCvxPool).notifyRewardAmount(cvxBal);
        }
    }

    function claimAllRewardToken() public {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            claimRewardToken(i);
        }
    }

    receive() external payable {}

    /* view functions */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolToken(uint256 _pid)
        external
        view
        override
        returns (address)
    {
        PoolInfo storage pool = poolInfo[_pid];

        return pool.lpToken;
    }

    function getPoolZapAddress(address _lpToken)
        external
        view
        override
        returns (address)
    {
        return curveZaps[_lpToken].zapAddress;
    }

    function calculateTokenAmount(
        uint256 _pid,
        uint256 _tokens,
        int128 _curveCoinId
    ) external view override returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];

        address curveSwapAddress = pool.curveSwapAddress;

        if (curveZaps[pool.lpToken].zapAddress != address(0)) {
            curveSwapAddress = curveZaps[pool.lpToken].zapAddress;

            if (curveZaps[pool.lpToken].isMetaFactory) {
                return
                    ICurveSwapV2(curveSwapAddress).calc_withdraw_one_coin(
                        pool.lpToken,
                        _tokens,
                        _curveCoinId
                    );
            }
        }

        return
            ICurveSwapV2(curveSwapAddress).calc_withdraw_one_coin(
                _tokens,
                _curveCoinId
            );
    }
}
