// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title Timelock
 * @notice Implements time-delayed execution for sensitive operations
 * @dev Used for liquidity adjustments to provide transparency to users
 *
 * Operations flow:
 * 1. Admin queues an operation with parameters
 * 2. Users can see the queued operation for the delay period (default 24h)
 * 3. After delay expires, admin can execute the operation
 * 4. Admin can cancel queued operations if needed
 */
contract Timelock is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for proposing operations
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    /// @notice Role for executing operations
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Role for cancelling operations
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    /// @notice Minimum delay before execution (default 24 hours)
    uint256 public constant MIN_DELAY = 24 hours;

    /// @notice Maximum delay allowed
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Grace period after delay expires before operation becomes stale
    uint256 public constant GRACE_PERIOD = 7 days;

    /// @notice Current configured delay
    uint256 public delay;

    /// @notice Operation status enum
    enum OperationStatus {
        NotQueued,
        Queued,
        Executed,
        Cancelled
    }

    /// @notice Queued operation details
    struct QueuedOperation {
        bytes32 id;
        address target;
        uint256 value;
        bytes data;
        uint256 queuedAt;
        uint256 executeAfter;
        OperationStatus status;
        string description;
    }

    /// @notice Mapping of operation ID to operation details
    mapping(bytes32 => QueuedOperation) public operations;

    /// @notice Array of all operation IDs for enumeration
    bytes32[] public operationIds;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an operation is queued
    event OperationQueued(
        bytes32 indexed id, address indexed target, uint256 value, bytes data, uint256 executeAfter, string description
    );

    /// @notice Emitted when an operation is executed
    event OperationExecuted(bytes32 indexed id);

    /// @notice Emitted when an operation is cancelled
    event OperationCancelled(bytes32 indexed id);

    /// @notice Emitted when delay is updated
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Timelock__OperationAlreadyQueued(bytes32 id);
    error Timelock__OperationNotQueued(bytes32 id);
    error Timelock__OperationNotReady(bytes32 id, uint256 executeAfter, uint256 currentTime);
    error Timelock__OperationStale(bytes32 id);
    error Timelock__OperationAlreadyExecuted(bytes32 id);
    error Timelock__InvalidDelay(uint256 delay);
    error Timelock__ExecutionFailed();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin, uint256 _delay) {
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) {
            revert Timelock__InvalidDelay(_delay);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(CANCELLER_ROLE, admin);

        delay = _delay;
    }

    /// @notice Allows receiving ETH for operations that need to send value
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                     USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Queues an operation for delayed execution
     * @param target The target contract address
     * @param value The ETH value to send
     * @param data The calldata to execute
     * @param description Human-readable description of the operation
     * @return id The unique operation ID
     */
    function queue(address target, uint256 value, bytes calldata data, string calldata description)
        external
        onlyRole(PROPOSER_ROLE)
        returns (bytes32 id)
    {
        id = keccak256(abi.encode(target, value, data, block.timestamp));

        if (operations[id].status == OperationStatus.Queued) {
            revert Timelock__OperationAlreadyQueued(id);
        }

        uint256 executeAfter = block.timestamp + delay;

        operations[id] = QueuedOperation({
            id: id,
            target: target,
            value: value,
            data: data,
            queuedAt: block.timestamp,
            executeAfter: executeAfter,
            status: OperationStatus.Queued,
            description: description
        });

        operationIds.push(id);

        emit OperationQueued(id, target, value, data, executeAfter, description);
    }

    /**
     * @notice Executes a queued operation after delay has passed
     * @param id The operation ID
     */
    function execute(bytes32 id) external onlyRole(EXECUTOR_ROLE) {
        QueuedOperation storage op = operations[id];

        if (op.status != OperationStatus.Queued) {
            if (op.status == OperationStatus.Executed) {
                revert Timelock__OperationAlreadyExecuted(id);
            }
            revert Timelock__OperationNotQueued(id);
        }

        if (block.timestamp < op.executeAfter) {
            revert Timelock__OperationNotReady(id, op.executeAfter, block.timestamp);
        }

        if (block.timestamp > op.executeAfter + GRACE_PERIOD) {
            revert Timelock__OperationStale(id);
        }

        op.status = OperationStatus.Executed;

        (bool success,) = op.target.call{value: op.value}(op.data);
        if (!success) revert Timelock__ExecutionFailed();

        emit OperationExecuted(id);
    }

    /**
     * @notice Cancels a queued operation
     * @param id The operation ID
     */
    function cancel(bytes32 id) external onlyRole(CANCELLER_ROLE) {
        QueuedOperation storage op = operations[id];

        if (op.status != OperationStatus.Queued) {
            revert Timelock__OperationNotQueued(id);
        }

        op.status = OperationStatus.Cancelled;

        emit OperationCancelled(id);
    }

    /**
     * @notice Updates the delay period
     * @param newDelay The new delay in seconds
     */
    function setDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) {
            revert Timelock__InvalidDelay(newDelay);
        }

        uint256 oldDelay = delay;
        delay = newDelay;

        emit DelayUpdated(oldDelay, newDelay);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the status of an operation
     * @param id The operation ID
     * @return The operation status
     */
    function getOperationStatus(bytes32 id) external view returns (OperationStatus) {
        return operations[id].status;
    }

    /**
     * @notice Gets all pending (queued) operations
     * @return pendingOps Array of pending operation details
     */
    function getPendingOperations() external view returns (QueuedOperation[] memory pendingOps) {
        uint256 count;

        for (uint256 i; i < operationIds.length; i++) {
            if (operations[operationIds[i]].status == OperationStatus.Queued) {
                count++;
            }
        }

        pendingOps = new QueuedOperation[](count);
        uint256 index;

        for (uint256 i; i < operationIds.length; i++) {
            if (operations[operationIds[i]].status == OperationStatus.Queued) {
                pendingOps[index] = operations[operationIds[i]];
                index++;
            }
        }
    }

    /**
     * @notice Checks if an operation is ready to execute
     * @param id The operation ID
     * @return ready True if the operation can be executed now
     */
    function isOperationReady(bytes32 id) external view returns (bool ready) {
        QueuedOperation storage op = operations[id];

        if (op.status != OperationStatus.Queued) return false;
        if (block.timestamp < op.executeAfter) return false;
        if (block.timestamp > op.executeAfter + GRACE_PERIOD) return false;

        return true;
    }

    /**
     * @notice Gets time remaining until operation can be executed
     * @param id The operation ID
     * @return remaining Seconds until ready (0 if ready or not queued)
     */
    function getTimeRemaining(bytes32 id) external view returns (uint256 remaining) {
        QueuedOperation storage op = operations[id];

        if (op.status != OperationStatus.Queued) return 0;
        if (block.timestamp >= op.executeAfter) return 0;

        return op.executeAfter - block.timestamp;
    }

    /**
     * @notice Gets the total number of operations
     */
    function getOperationCount() external view returns (uint256) {
        return operationIds.length;
    }
}
