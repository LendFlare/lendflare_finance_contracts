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

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract LendFlareTokenLocker {
    using SafeERC20 for IERC20;

    address public owner;
    address public token;
    uint256 public start_time;
    uint256 public end_time;

    mapping(address => uint256) public initial_locked;
    mapping(address => uint256) public total_claimed;
    mapping(address => uint256) public disabled_at;

    uint256 public initial_locked_supply;
    uint256 public unallocated_supply;

    event Fund(address indexed recipient, uint256 amount);
    event Claim(address indexed recipient, uint256 amount);
    event ToggleDisable(address recipient, bool disabled);

    constructor(
        address _owner,
        address _token,
        uint256 _start_time,
        uint256 _end_time
    ) public {
        require(
            _start_time >= block.timestamp,
            "_start_time >= block.timestamp"
        );
        require(_end_time > _start_time, "_end_time > _start_time");

        owner = _owner;
        token = _token;
        start_time = _start_time;
        end_time = _end_time;
    }

    function setOwner(address _owner) external {
        require(
            msg.sender == owner,
            "LendFlareTokenLocker: !authorized setOwner"
        );

        owner = _owner;
    }

    function add_tokens(uint256 _amount) public {
        require(
            msg.sender == owner,
            "LendFlareTokenLocker: !authorized add_tokens"
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        unallocated_supply += _amount;
    }

    function fund(address[] memory _recipients, uint256[] memory _amounts)
        public
    {
        require(msg.sender == owner, "LendFlareTokenLocker: !authorized fund");
        require(
            _recipients.length == _amounts.length,
            "_recipients != _amounts"
        );

        uint256 _total_amount;

        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 amount = _amounts[i];
            address recipient = _recipients[i];

            if (recipient == address(0)) {
                break;
            }

            _total_amount += amount;

            initial_locked[recipient] += amount;
            emit Fund(recipient, amount);
        }

        initial_locked_supply += _total_amount;
        unallocated_supply -= _total_amount;
    }

    function toggle_disable(address _recipient) public {
        require(
            msg.sender == owner,
            "LendFlareTokenLocker: !authorized toggle_disable"
        );

        bool is_disabled = disabled_at[_recipient] == 0;

        if (is_disabled) {
            disabled_at[_recipient] = block.timestamp;
        } else {
            disabled_at[_recipient] = 0;
        }

        emit ToggleDisable(_recipient, is_disabled);
    }

    function claim() public {
        address addr = msg.sender;

        uint256 t = disabled_at[addr];

        if (t == 0) {
            t = block.timestamp;
        }

        uint256 claimable = _total_vested_of(addr, t) - total_claimed[addr];

        total_claimed[addr] += claimable;

        IERC20(token).safeTransfer(addr, claimable);

        emit Claim(addr, claimable);
    }

    function _total_vested_of(address _recipient, uint256 _time)
        internal
        view
        returns (uint256)
    {
        if (_time == 0) _time = block.timestamp;

        uint256 start = start_time;
        uint256 end = end_time;
        uint256 locked = initial_locked[_recipient];

        if (_time < start) {
            return 0;
        }

        return min((locked * (_time - start)) / (end - start), locked);
    }

    function _total_vested() internal view returns (uint256) {
        uint256 start = start_time;
        uint256 end = end_time;
        uint256 locked = initial_locked_supply;

        if (block.timestamp < start) {
            return 0;
        }

        return
            min((locked * (block.timestamp - start)) / (end - start), locked);
    }

    function vestedSupply() public view returns (uint256) {
        return _total_vested();
    }

    function lockedSupply() public view returns (uint256) {
        return initial_locked_supply - _total_vested();
    }

    function vestedOf(address _recipient) public view returns (uint256) {
        return _total_vested_of(_recipient, block.timestamp);
    }

    function balanceOf(address _recipient) public view returns (uint256) {
        return
            _total_vested_of(_recipient, block.timestamp) -
            total_claimed[_recipient];
    }

    function lockedOf(address _recipient) public view returns (uint256) {
        return
            initial_locked[_recipient] -
            _total_vested_of(_recipient, block.timestamp);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract LendFlareTokenLockerFactory {
    uint256 public totalLockers;
    mapping(uint256 => address) public lockers;

    address public owner;

    event CreateLocker(
        uint256 indexed uniqueId,
        address indexed locker,
        string description
    );

    constructor() public {
        owner = msg.sender;
    }

    function setOwner(address _owner) external {
        require(
            msg.sender == owner,
            "LendFlareTokenLockerFactory: !authorized setOwner"
        );

        owner = _owner;
    }

    function createLocker(
        uint256 _uniqueId,
        address _token,
        uint256 _start_time,
        uint256 _end_time,
        address _owner,
        string memory description
    ) external returns (address) {
        require(
            msg.sender == owner,
            "LendFlareTokenLockerFactory: !authorized createLocker"
        );
        require(lockers[_uniqueId] == address(0), "!_uniqueId");

        LendFlareTokenLocker locker = new LendFlareTokenLocker(
            _owner,
            _token,
            _start_time,
            _end_time
        );

        lockers[_uniqueId] = address(locker);

        totalLockers++;

        emit CreateLocker(_uniqueId, address(locker), description);
    }
}
