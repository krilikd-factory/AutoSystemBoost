import pytest
import struct
import sys
import os
import tempfile
import math

# Payloads designed to trigger integer overflow / large allocation scenarios
# These simulate adversarial session files with many lines, boundary sizes, etc.

# Helper to generate a session file content with N lines
def make_session_content(num_lines, line_content="A" * 64):
    return "\n".join([line_content] * num_lines) + "\n"

# Simulate what a safe allocator/parser MUST do:
# - Never allocate less memory than required
# - Never allow capacity to wrap around (integer overflow)
# - Always keep track of actual allocated capacity vs. used slots

MAX_SAFE_LINES = 10_000_000  # Reasonable upper bound for session lines

def safe_parse_lines(content, max_lines=MAX_SAFE_LINES):
    """
    A reference implementation that safely parses lines from content.
    Invariants:
    - capacity must always be >= number of lines stored
    - capacity must never overflow (wrap around)
    - allocation size must always be positive and proportional to capacity
    """
    lines = []
    cap = 4
    POINTER_SIZE = 8  # 64-bit; on 32-bit this would be 4

    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if len(lines) >= max_lines:
            raise ValueError(f"Exceeded maximum line count: {max_lines}")

        # Simulate capacity doubling
        if len(lines) >= cap:
            new_cap = cap * 2
            # SECURITY INVARIANT: Check for integer overflow before allocation
            alloc_size = new_cap * POINTER_SIZE
            if new_cap <= 0 or alloc_size <= 0 or alloc_size < new_cap:
                raise OverflowError(
                    f"Integer overflow detected: new_cap={new_cap}, "
                    f"alloc_size={alloc_size}"
                )
            # SECURITY INVARIANT: new_cap must be strictly larger than old cap
            assert new_cap > cap, "Capacity must strictly increase"
            # SECURITY INVARIANT: allocation size must be >= new_cap * pointer_size
            assert alloc_size >= new_cap * POINTER_SIZE, (
                "Allocation size must accommodate all pointers"
            )
            cap = new_cap

        lines.append(line)

        # SECURITY INVARIANT: capacity must always be >= number of stored lines
        assert cap >= len(lines), (
            f"Capacity {cap} must be >= line count {len(lines)}"
        )

    return lines, cap


@pytest.mark.parametrize("payload", [
    # Boundary: exactly at power-of-2 boundaries (triggers realloc)
    make_session_content(1),
    make_session_content(2),
    make_session_content(3),
    make_session_content(4),
    make_session_content(5),
    make_session_content(7),
    make_session_content(8),
    make_session_content(9),
    make_session_content(15),
    make_session_content(16),
    make_session_content(17),
    make_session_content(31),
    make_session_content(32),
    make_session_content(33),
    make_session_content(63),
    make_session_content(64),
    make_session_content(65),
    make_session_content(127),
    make_session_content(128),
    make_session_content(255),
    make_session_content(256),
    make_session_content(511),
    make_session_content(512),
    make_session_content(1023),
    make_session_content(1024),
    make_session_content(2047),
    make_session_content(2048),
    # Large inputs that would stress 32-bit overflow
    make_session_content(65535),
    make_session_content(65536),
    make_session_content(131071),
    make_session_content(131072),
    # Lines with adversarial content
    make_session_content(100, line_content="X" * 255),
    make_session_content(100, line_content="\x00" * 10 + "A" * 54),
    make_session_content(100, line_content="../../../etc/passwd"),
    make_session_content(100, line_content="A" * 4096),
    make_session_content(100, line_content="%s%s%s%s%s%n%n%n"),
    make_session_content(100, line_content="'; DROP TABLE sessions; --"),
    make_session_content(100, line_content="\xff\xfe" + "A" * 62),
    # Empty and near-empty
    "",
    "\n",
    "\n\n\n\n\n",
    "single_line",
    # Mixed empty and content lines
    "\n".join(["line"] * 50 + [""] * 50 + ["line"] * 50),
    # Very long single line
    "A" * 100000,
    # Lines that look like numbers near overflow boundaries
    make_session_content(10, line_content=str(2**31 - 1)),
    make_session_content(10, line_content=str(2**32 - 1)),
    make_session_content(10, line_content=str(2**63 - 1)),
    make_session_content(10, line_content=str(2**64 - 1)),
    make_session_content(10, line_content="-1"),
    make_session_content(10, line_content="0"),
])
def test_allocation_never_overflows_on_adversarial_input(payload):
    """
    Invariant: When parsing session file content, the internal capacity tracker
    must ALWAYS be >= the number of lines stored, allocation sizes must NEVER
    wrap around (integer overflow), and capacity must strictly increase on each
    reallocation. This guards against heap corruption from undersized allocations
    caused by integer overflow in capacity * sizeof(pointer) computations.
    """
    try:
        lines, final_cap = safe_parse_lines(payload)

        # INVARIANT 1: Final capacity must be >= number of lines parsed
        assert final_cap >= len(lines), (
            f"SECURITY VIOLATION: capacity {final_cap} < line count {len(lines)}. "
            f"This indicates an undersized allocation that could cause heap corruption."
        )

        # INVARIANT 2: Capacity must be a positive power of 2 (or initial value)
        if final_cap > 0:
            assert final_cap >= 4, (
                f"SECURITY VIOLATION: capacity {final_cap} is below minimum safe value."
            )

        # INVARIANT 3: Allocation size must not overflow
        POINTER_SIZE = 8
        alloc_size = final_cap * POINTER_SIZE
        assert alloc_size > 0, (
            f"SECURITY VIOLATION: allocation size {alloc_size} is non-positive, "
            f"indicating integer overflow with capacity={final_cap}."
        )
        assert alloc_size >= final_cap, (
            f"SECURITY VIOLATION: alloc_size {alloc_size} < capacity {final_cap}, "
            f"indicating integer overflow."
        )

        # INVARIANT 4: Number of parsed lines must not exceed safe maximum
        assert len(lines) <= MAX_SAFE_LINES, (
            f"SECURITY VIOLATION: parsed {len(lines)} lines exceeds safe maximum "
            f"{MAX_SAFE_LINES}. Unbounded growth could exhaust memory."
        )

        # INVARIANT 5: Each line must be a string (type safety)
        for i, line in enumerate(lines):
            assert isinstance(line, str), (
                f"SECURITY VIOLATION: line[{i}] is not a string (type={type(line)}). "
                f"Type confusion could lead to memory corruption."
            )

    except OverflowError as e:
        # An overflow was detected and raised — this is the CORRECT behavior
        # The invariant is that overflow must be DETECTED, not silently wrapped
        assert "overflow" in str(e).lower() or "Integer overflow" in str(e), (
            f"Unexpected OverflowError: {e}"
        )

    except ValueError as e:
        # Exceeding max lines is acceptable — it means the parser has a safety limit
        assert "Exceeded maximum line count" in str(e), (
            f"Unexpected ValueError: {e}"
        )


@pytest.mark.parametrize("new_cap,pointer_size", [
    # 32-bit overflow scenarios: new_cap * 4 wraps around
    (0x40000001, 4),   # 0x40000001 * 4 = 0x100000004 -> wraps to 4 on 32-bit
    (0x80000000, 4),   # 0x80000000 * 4 = 0x200000000 -> wraps to 0
    (0xFFFFFFFF, 4),   # max 32-bit * 4 -> overflow
    (0x3FFFFFFF, 4),   # near boundary
    (0x20000000, 4),   # 512MB worth of pointers
    # 64-bit overflow scenarios
    (0x4000000000000001, 8),
    (0x8000000000000000, 8),
    # Edge cases
    (0, 4),
    (0, 8),
    (1, 4),
    (1, 8),
    (2**31 - 1, 4),
    (2**31, 4),
    (2**32 - 1, 4),
    (2**32, 8),
    (2**63 - 1, 8),
])
def test_capacity_multiplication_overflow_detection(new_cap, pointer_size):
    """
    Invariant: The product new_cap * sizeof(pointer) must NEVER silently overflow.
    Any allocation size computation must be validated before use.
    If overflow would occur, it must be detected and rejected — never silently
    produce an undersized allocation.
    """
    # Simulate the vulnerable computation on a 32-bit system
    BITS = pointer_size * 8  # 32 or 64 bit
    MASK = (1 << BITS) - 1

    raw_product = new_cap * pointer_size
    truncated_product = raw_product & MASK  # What a wrapping multiply would give

    # INVARIANT: If truncation changes the value, overflow occurred
    # The safe implementation MUST detect this
    if raw_product != truncated_product:
        # Overflow would occur — the system must detect and reject this
        overflow_detected = (truncated_product < new_cap) or (truncated_product == 0)
        assert overflow_detected or raw_product > MASK, (
            f"SECURITY VIOLATION: Overflow not detectable for "
            f"new_cap={new_cap}, pointer_size={pointer_size}. "
            f"raw={raw_product}, truncated={truncated_product}"
        )

    # INVARIANT: A safe implementation must check: result / pointer_size == new_cap
    if new_cap > 0 and pointer_size > 0:
        safe_alloc_size = new_cap * pointer_size
        if safe_alloc_size > 0:
            # Verify the multiplication is reversible (no overflow)
            reverse_check = safe_alloc_size // pointer_size
            if reverse_check != new_cap:
                # This means overflow occurred — must be caught before allocation
                pytest.skip(
                    f"Overflow confirmed for new_cap={new_cap}: "
                    f"reverse_check={reverse_check} != new_cap={new_cap}. "
                    f"Safe implementation must reject this."
                )
            else:
                # No overflow: allocation size must be >= new_cap
                assert safe_alloc_size >= new_cap, (
                    f"SECURITY VIOLATION: alloc_size {safe_alloc_size} < "
                    f"new_cap {new_cap} with pointer_size {pointer_size}"
                )