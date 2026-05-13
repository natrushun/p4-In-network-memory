#!/usr/bin/env python3
"""
client.py - In-network memory kliens
Használat: python3 client.py
"""

from scapy.all import *
import sys

# ─── KONSTANSOK ───────────────────────────────────────────────────────────────

ETHERTYPE_MEM = 0x1234
SWITCH_MAC    = "00:01:02:03:04:05"
IFACE         = "eth0"

OPCODE_READ   = 0x01
OPCODE_WRITE  = 0x02
OPCODE_LOCK   = 0x03
OPCODE_UNLOCK = 0x04

STATUS_OK     = 0x00
STATUS_LOCKED = 0x01
STATUS_ERROR  = 0x02

STATUS_NAMES = {
    STATUS_OK:     "OK",
    STATUS_LOCKED: "LOCKED",
    STATUS_ERROR:  "ERROR",
}

# ─── LOCK NYILVÁNTARTÁS ───────────────────────────────────────────────────────

# azokat a címeket tároljuk amiket mi lockoltunk
locked_addresses = set()

# ─── EGYEDI SCAPY HEADER ──────────────────────────────────────────────────────

class MemHeader(Packet):
    """A mi egyedi memory protokoll headerünk."""
    name = "MemHeader"
    fields_desc = [
        ByteField("opcode",  0),
        IntField ("address", 0),
        IntField ("value",   0),
        ByteField("status",  0),
    ]

bind_layers(Ether, MemHeader, type=ETHERTYPE_MEM)

# ─── CSOMAG KÜLDÉS / FOGADÁS ──────────────────────────────────────────────────

def send_and_receive(opcode, address, value=0):
    my_mac = get_if_hwaddr(IFACE)

    pkt = (
        Ether(src=my_mac, dst=SWITCH_MAC, type=ETHERTYPE_MEM) /
        MemHeader(opcode=opcode, address=address, value=value, status=0)
    )

    answered, _ = srp(pkt, iface=IFACE, timeout=2, verbose=False)

    if not answered:
        print("[!] Nem érkezett válasz a switchtől.")
        return None, None

    response = answered[0][1]

    if MemHeader not in response:
        print("[!] A válasz nem tartalmaz MemHeader-t.")
        return None, None

    return response[MemHeader].value, response[MemHeader].status

# ─── MŰVELETEK ────────────────────────────────────────────────────────────────

def mem_read(address):
    """Kiolvas egy értéket a megadott memória címről."""
    print(f"[>] READ  address={address}")
    value, status = send_and_receive(OPCODE_READ, address)

    if status is None:
        return

    status_name = STATUS_NAMES.get(status, f"UNKNOWN(0x{status:02x})")
    if status == STATUS_OK:
        print(f"[<] OK    value={value}")
    else:
        print(f"[<] {status_name}")


def mem_write(address, value):
    """Beír egy értéket a megadott memória címre."""
    print(f"[>] WRITE address={address} value={value}")
    _, status = send_and_receive(OPCODE_WRITE, address, value)

    if status is None:
        return

    status_name = STATUS_NAMES.get(status, f"UNKNOWN(0x{status:02x})")
    if status == STATUS_OK:
        # write implicit lockot szerez, nyilvántartjuk
        locked_addresses.add(address)
        print(f"[<] OK")
    else:
        print(f"[<] {status_name}")


def mem_lock(address):
    """Lockot szerez a megadott memória címre."""
    print(f"[>] LOCK  address={address}")
    _, status = send_and_receive(OPCODE_LOCK, address)

    if status is None:
        return

    status_name = STATUS_NAMES.get(status, f"UNKNOWN(0x{status:02x})")
    if status == STATUS_OK:
        # sikeresen lockoltunk, nyilvántartjuk
        locked_addresses.add(address)
        print(f"[<] OK")
    else:
        print(f"[<] {status_name}")


def mem_unlock(address):
    """Feloldja a lockot a megadott memória címen."""
    print(f"[>] UNLOCK address={address}")
    _, status = send_and_receive(OPCODE_UNLOCK, address)

    if status is None:
        return

    status_name = STATUS_NAMES.get(status, f"UNKNOWN(0x{status:02x})")
    if status == STATUS_OK:
        # sikeresen feloldottuk, töröljük a nyilvántartásból
        locked_addresses.discard(address)
        print(f"[<] OK")
    else:
        print(f"[<] {status_name}")


def cleanup():
    """Kilépéskor feloldja az összes lockot amit ez a kliens szerzett."""
    if not locked_addresses:
        return

    print(f"\n[*] Kilépés előtt a lockok feloldása: {locked_addresses}")
    # másolatot csinálunk mert unlock közben módosul a set
    for address in list(locked_addresses):
        mem_unlock(address)
    print("[*] Minden lock feloldva.")

# ─── INTERAKTÍV MENÜ ──────────────────────────────────────────────────────────

def print_menu():
    print("""
┌─────────────────────────────────┐
│   In-Network Memory Client      │
├─────────────────────────────────┤
│  1. READ   <address>            │
│  2. WRITE  <address> <value>    │
│  3. LOCK   <address>            │
│  4. UNLOCK <address>            │
│  0. Kilépés                     │
└─────────────────────────────────┘""")

def main():
    print(f"[*] Interfész: {IFACE}  |  MAC: {get_if_hwaddr(IFACE)}")
    print(f"[*] Switch MAC: {SWITCH_MAC}")

    while True:
        print_menu()
        try:
            line = input(">>> ").strip().split()
        except (KeyboardInterrupt, EOFError):
            # Ctrl+C vagy Ctrl+D esetén is cleanup fut
            cleanup()
            print("\n[*] Kilépés.")
            sys.exit(0)

        if not line:
            continue

        cmd = line[0]

        try:
            if cmd in ("0", "quit", "exit"):
                cleanup()
                print("[*] Kilépés.")
                sys.exit(0)

            elif cmd in ("1", "read", "READ"):
                address = int(line[1])
                mem_read(address)

            elif cmd in ("2", "write", "WRITE"):
                address = int(line[1])
                value   = int(line[2])
                mem_write(address, value)

            elif cmd in ("3", "lock", "LOCK"):
                address = int(line[1])
                mem_lock(address)

            elif cmd in ("4", "unlock", "UNLOCK"):
                address = int(line[1])
                mem_unlock(address)

            else:
                print("[!] Ismeretlen parancs.")

        except (IndexError, ValueError):
            print("[!] Hibás paraméterek. Példa: write 0 42")

if __name__ == "__main__":
    main()