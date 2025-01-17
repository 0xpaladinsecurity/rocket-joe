// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./RocketJoeToken.sol";

/// @title Rocket Joe Staking
/// @author Trader Joe
/// @notice Stake JOE to earn rJOE
contract RocketJoeStaking is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct UserInfo {
        uint256 amount; // How many JOE tokens the user has provided
        uint256 rewardDebt; // Reward debt. See explanation below
        //
        // We do some fancy math here. Basically, any point in time, the amount of JOEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * accRJoePerShare) / PRECISION - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. `accRJoePerShare` (and `lastRewardTimestamp`) gets updated
        //   2. User receives the pending reward sent to his/her address
        //   3. User's `amount` gets updated
        //   4. User's `rewardDebt` gets updated
    }

    IERC20Upgradeable public joe;
    uint256 public lastRewardTimestamp;

    /// @dev Accumulated rJOE per share, times PRECISION. See above
    uint256 public accRJoePerShare;
    /// @notice Precision of accRJoePerShare
    uint256 private PRECISION;

    /// @dev The maximum emission rate per second
    uint256 public MAX_EMISSION_RATE;

    RocketJoeToken public rJoe;
    uint256 public rJoePerSec;

    /// @dev Balance of JOE held by contract
    uint256 public totalJoeStaked;

    /// @dev Info of each user that stakes LP tokens
    mapping(address => UserInfo) public userInfo;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 _rJoePerSec);

    /// @notice Initialize with needed parameters
    /// @param _joe Address of the JOE token contract
    /// @param _rJoe Address of the rJOE token contract
    /// @param _rJoePerSec Number of rJOE tokens created per second
    /// @param _startTime Timestamp at which rJOE rewards starts
    function initialize(
        IERC20Upgradeable _joe,
        RocketJoeToken _rJoe,
        uint256 _rJoePerSec,
        uint256 _startTime
    ) external initializer {
        __Ownable_init();

        require(
            _startTime > block.timestamp,
            "RocketJoeStaking: rJOE minting needs to start after the current timestamp"
        );

        PRECISION = 1e18;
        MAX_EMISSION_RATE = 1e24;
        require(
            _rJoePerSec <= MAX_EMISSION_RATE,
            "RocketJoeStaking: emission rate too high"
        );
        joe = _joe;
        rJoe = _rJoe;
        rJoePerSec = _rJoePerSec;
        lastRewardTimestamp = _startTime;
    }

    /// @notice Get pending rJoe for a given `_user`
    /// @param _user The user to lookup
    /// @return The number of pending rJOE tokens for `_user`
    function pendingRJoe(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 joeSupply = totalJoeStaked;
        uint256 _accRJoePerShare = accRJoePerShare;

        if (block.timestamp > lastRewardTimestamp && joeSupply != 0) {
            uint256 multiplier = block.timestamp - lastRewardTimestamp;
            uint256 rJoeReward = multiplier * rJoePerSec;
            _accRJoePerShare += (rJoeReward * PRECISION) / joeSupply;
        }
        return (user.amount * _accRJoePerShare) / PRECISION - user.rewardDebt;
    }

    /// @notice Deposit joe to RocketJoeStaking for rJoe allocation
    /// @param _amount Amount of JOE to deposit
    function deposit(uint256 _amount) external {
        UserInfo storage user = userInfo[msg.sender];

        updatePool();

        uint256 pending;
        if (user.amount > 0) {
            pending =
                (user.amount * accRJoePerShare) /
                PRECISION -
                user.rewardDebt;
        }
        user.amount += _amount;
        user.rewardDebt = (user.amount * accRJoePerShare) / PRECISION;
        totalJoeStaked += _amount;

        if (_amount != 0)
            joe.safeTransferFrom(msg.sender, address(this), _amount);
        if (pending != 0) _safeRJoeTransfer(msg.sender, pending);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraw JOE and accumulated rJOE from RocketJoeStaking
    /// @param _amount Amount of JOE to withdraw
    function withdraw(uint256 _amount) external {
        UserInfo storage user = userInfo[msg.sender];
        require(
            user.amount >= _amount,
            "RocketJoeStaking: withdraw amount exceeds balance"
        );

        updatePool();

        uint256 pending = (user.amount * accRJoePerShare) /
            PRECISION -
            user.rewardDebt;

        user.amount -= _amount;
        user.rewardDebt = (user.amount * accRJoePerShare) / PRECISION;

        if (pending > 0) _safeRJoeTransfer(msg.sender, pending);
        totalJoeStaked -= _amount;
        joe.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];

        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        totalJoeStaked -= _amount;
        joe.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _amount);
    }

    /// @notice Update emission rate
    /// @param _rJoePerSec The new value for rJoePerSec
    function updateEmissionRate(uint256 _rJoePerSec) external onlyOwner {
        require(
            _rJoePerSec <= MAX_EMISSION_RATE,
            "RocketJoeStaking: emission rate too high"
        );
        updatePool();
        rJoePerSec = _rJoePerSec;
        emit UpdateEmissionRate(msg.sender, _rJoePerSec);
    }

    /// @notice Update reward variables of the given pool with latest data
    function updatePool() public {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }
        uint256 joeSupply = totalJoeStaked;
        if (joeSupply == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 multiplier = block.timestamp - lastRewardTimestamp;
        uint256 rJoeReward = multiplier * rJoePerSec;
        accRJoePerShare += (rJoeReward * PRECISION) / joeSupply;
        lastRewardTimestamp = block.timestamp;

        rJoe.mint(address(this), rJoeReward);
    }

    /// @notice Safe rJoe transfer function, just in case if rounding error causes pool to not have enough JOEs
    /// @param _to Address that wil receive rJoe
    /// @param _amount The amount to send
    function _safeRJoeTransfer(address _to, uint256 _amount) internal {
        uint256 rJoeBal = rJoe.balanceOf(address(this));
        if (_amount > rJoeBal) {
            IERC20Upgradeable(address(rJoe)).safeTransfer(_to, rJoeBal);
        } else {
            IERC20Upgradeable(address(rJoe)).safeTransfer(_to, _amount);
        }
    }
}
