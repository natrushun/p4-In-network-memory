# In-Network Memory

## Project Overview

The goal of this project is to implement an **in-network memory** system using P4 programmable switches.
Data is stored directly inside the switch using P4 **registers**.
Hosts can read and write this memory by sending specially crafted packets to the switch.
The in-network memory can be shared between multiple servers, and a **locking mechanism** ensures data consistency when multiple hosts access the same memory location simultaneously.

Locks have a **20-second timeout**: if a host holds a lock and does not release it within 20 seconds, the next WRITE or LOCK request from another host will automatically expire the old lock and acquire it.

---

## Technologies Used

| Technology | Purpose |
|---|---|
| **P4** | Data plane programming – register operations, packet parsing, custom protocol |
| **BMv2 switch** | P4 switch used for simulation |
| **Kathara** | Network emulation framework – used to set up the virtual topology |

---

## Network Topology (PoC)

The proof of concept uses a minimal topology:

```
+--------+        +---------------------+        +--------+
|        |        |                     |        |        |
| Host 1 +--------+   P4 Switch (BMv2)  +--------+ Host 2 |
|  (h1)  |        |                     |        |  (h2)  |
+--------+        |   In-network memory |        +--------+
                  |   (P4 Registers)    |
                  +---------------------+
```

- **h1** and **h2** are end hosts running inside Kathara containers
- The **P4 switch** stores shared memory in its registers
- Both hosts can send READ, WRITE, and LOCK/UNLOCK packets to the switch
- The switch processes these packets in the **data plane** and responds accordingly

---

## Custom Protocol

A custom packet header is defined to communicate with the in-network memory:

| Field | Description |
|---|---|
| `opcode` | Operation type: `0x01` = READ, `0x02` = WRITE, `0x03` = LOCK, `0x04` = UNLOCK |
| `address` | Memory address (index into the register array) |
| `value` | Data to write (WRITE) or data returned by the switch (READ) |
| `status` | Response status: `0x00` = OK, `0x01` = LOCKED, `0x02` = ERROR |

The header is placed directly after the Ethernet header using a custom EtherType (`0x1234`):

```
[ Ethernet (etherType=0x1234) | opcode | address | value | status ]
```

#### Request (Host → Switch)
- `opcode`: operation type
- `address`: target memory index
- `value`: used for WRITE operations
- `status`: ignored (set to 0)

#### Response (Switch → Host)
- `opcode`: echoed from request
- `address`: echoed from request
- `value`: contains READ operation result 
- `status`: operation result

- For READ operations, the `value` field in the response contains the data stored at the given address.
- For WRITE operations, the `value` field is ignored in the response.
- If an operation fails (e.g., due to a lock), the `status` field is set accordingly.

---

## P4 Implementation Details

### Registers

The in-network memory is implemented as a P4 register array:

```p4
register<bit<32>>(1024) memory;       // Main memory – 1024 x 32-bit cells
register<bit<48>>(1024) lock_owner;   // Lock owner (MAC address), 0 = free
register<bit<48>>(1024) lock_time;    // Lock acquisition timestamp (microseconds)
```

### Operations

- **READ**:  
  The switch reads the value at the given address from the `memory` register and sends it back to the requesting host.  
  This operation does not require a lock.

- **WRITE**:  
  The switch checks the `lock_owner` for the given address:
  - If the address is free (`lock_owner == 0`), the switch:
    - assigns the lock to the requesting host (`lock_owner = src_mac`)
    - records the current timestamp in `lock_time`
    - writes the new value into `memory`
  - If the requesting host already owns the lock (`lock_owner == src_mac`), the write is allowed
  - If another host owns the lock, the switch checks whether the lock has expired (older than 20 seconds):
    - If expired: the old lock is released, the requesting host acquires it and the write proceeds
    - If not expired: the operation is rejected with status `LOCKED`

- **LOCK**:  
  The switch attempts to acquire the lock for the given address:
  - If the address is free (`lock_owner == 0`), it stores the requester's MAC address in `lock_owner`, records the timestamp in `lock_time`, and responds with status `OK`
  - If the same host already owns the lock, the operation succeeds (idempotent)
  - If another host owns the lock, the switch checks whether the lock has expired:
    - If expired: the old lock is released and the requesting host acquires it
    - If not expired: the request is rejected with status `LOCKED`

- **UNLOCK**:  
  The switch releases the lock only if the requesting host is the owner:
  - If `lock_owner == src_mac`, both `lock_owner` and `lock_time` are reset to `0` (free)
  - Otherwise, the operation is rejected with status `ERROR`

### Lock Timeout

Locks are automatically expired after **20 seconds** of inactivity. The timeout is enforced in the data plane using the `ingress_global_timestamp` metadata field, which provides the current time in microseconds:

```p4
const bit<48> LOCK_TIMEOUT = 20000000;  // 20 seconds in microseconds

elapsed = ingress_global_timestamp - lock_time[address];
if (elapsed >= LOCK_TIMEOUT) {
    // lock expired – release and acquire
}
```

This mechanism ensures that if a host crashes or loses connectivity without releasing its locks, other hosts can eventually acquire the lock after the timeout period.
