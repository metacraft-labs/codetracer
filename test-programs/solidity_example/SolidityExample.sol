// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SolidityExample — a minimal ERC20-like token for CodeTracer UI tests.
///
/// This contract exercises the EVM/Solidity features that the UI tests verify:
///   - State variables (mapping, uint256, string)
///   - Internal function calls (_transfer, _mint)
///   - Solidity events (Transfer, Approval)
///   - Storage reads/writes (balances, allowances, totalSupply)
///
/// It is intentionally small so traces are fast to record and replay.
contract SolidityExample {
    // -----------------------------------------------------------------------
    // State variables
    // -----------------------------------------------------------------------

    /// Human-readable name of the token, e.g. "ExampleToken".
    string public name;

    /// Ticker symbol, e.g. "EXT".
    string public symbol;

    /// Fixed decimal precision (matches most ERC-20 tokens).
    uint8 public constant decimals = 18;

    /// Total token supply minted so far.
    uint256 public totalSupply;

    /// Token balances per address.
    mapping(address => uint256) public balanceOf;

    /// Approved spending allowances: owner → spender → amount.
    mapping(address => mapping(address => uint256)) public allowance;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// Emitted on every token transfer, including mints (from == address(0))
    /// and burns (to == address(0)).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// Emitted when an owner approves a spender to spend up to `value` tokens.
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor() {
        name = "Example Token";
        symbol = "EXT";
    }

    // -----------------------------------------------------------------------
    // Public interface
    // -----------------------------------------------------------------------

    /// @notice Transfer `amount` tokens from the caller to `to`.
    /// @return success Always true; reverts on failure.
    function transfer(
        address to,
        uint256 amount
    ) public returns (bool success) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Approve `spender` to withdraw up to `amount` from the caller.
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `from` to `to` using the caller's
    ///         pre-approved allowance.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "SolidityExample: allowance exceeded");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    // -----------------------------------------------------------------------
    // Internal helpers — targets for call-trace inspection in UI tests
    // -----------------------------------------------------------------------

    /// @dev Core transfer logic. Writes to `balanceOf` and emits `Transfer`.
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "SolidityExample: transfer from zero address");
        require(to != address(0), "SolidityExample: transfer to zero address");

        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "SolidityExample: insufficient balance");

        // Storage write: debit sender
        balanceOf[from] = fromBalance - amount;
        // Storage write: credit recipient
        balanceOf[to] = balanceOf[to] + amount;

        emit Transfer(from, to, amount);
    }

    /// @dev Mint `amount` tokens and assign them to `account`.
    ///      Increases `totalSupply` and emits a Transfer from the zero address.
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "SolidityExample: mint to zero address");

        totalSupply = totalSupply + amount;
        balanceOf[account] = balanceOf[account] + amount;

        emit Transfer(address(0), account, amount);
    }

    // -----------------------------------------------------------------------
    // Test entry point — called by the EVM recorder test harness
    // -----------------------------------------------------------------------

    /// @notice Mint tokens to two accounts and perform a transfer between them.
    ///
    /// Execution path exercised:
    ///   1. _mint(alice, 1000) — emits Transfer(0x0 → alice, 1000)
    ///   2. _mint(bob,   500)  — emits Transfer(0x0 → bob,    500)
    ///   3. _transfer(alice → bob, 200) — emits Transfer(alice → bob, 200)
    ///
    /// Final balances: alice = 800, bob = 700, totalSupply = 1500.
    function run() public { address alice = address(uint160(0xA11CE)); address bob = address(uint160(0xB0B));
        _mint(alice, 1000);
        _mint(bob, 500);
        _transfer(alice, bob, 200);
    }
}
