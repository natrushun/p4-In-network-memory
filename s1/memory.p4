/* memory.p4 - In-network memory implemented in P4 */

#include <core.p4>
#include <v1model.p4>

/*************************************************************************
 * KONSTANSOK
 *************************************************************************/

const bit<16> ETHERTYPE_MEM = 0x1234;

const bit<8>  OPCODE_READ   = 0x01;
const bit<8>  OPCODE_WRITE  = 0x02;
const bit<8>  OPCODE_LOCK   = 0x03;
const bit<8>  OPCODE_UNLOCK = 0x04;

const bit<8>  STATUS_OK     = 0x00;
const bit<8>  STATUS_LOCKED = 0x01;
const bit<8>  STATUS_ERROR  = 0x02;

// 20 másodperc mikroszekundumban
const bit<48> LOCK_TIMEOUT  = 20000000;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header mem_t {
    bit<8>  opcode;
    bit<32> address;
    bit<32> value;
    bit<8>  status;
}

struct headers_t {
    ethernet_t ethernet;
    mem_t      mem;
}

struct metadata_t { }

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETHERTYPE_MEM: parse_mem;
            default: accept;
        }
    }

    state parse_mem {
        packet.extract(hdr.mem);
        transition accept;
    }
}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply { }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) {

    // --- REGISZTEREK ---
    // 1024 darab 32 bites memória cella
    register<bit<32>>(1024) memory;

    // 1024 darab 48 bites lock tulajdonos (MAC cím), 0 = szabad
    register<bit<48>>(1024) lock_owner;

    // 1024 darab 48 bites timestamp – mikor lett lockozva (mikroszekundum)
    register<bit<48>>(1024) lock_time;

    // --- SEGÉDVÁLTOZÓK ---
    bit<32> mem_value;   // ide olvassuk ki a memory register értékét
    bit<48> owner;       // ide olvassuk ki a lock_owner register értékét
    bit<48> locked_at;   // ide olvassuk ki a lock_time register értékét
    bit<48> elapsed;     // ennyi idő telt el a lock megszerzése óta


    // --- SEGÉDFÜGGVÉNY: lejárt-e a lock? ---
    // visszatér true-val ha a lock lejárt (20 másodpercnél régebbi)
    action check_timeout() {
        lock_time.read(locked_at, hdr.mem.address);
        elapsed = standard_metadata.ingress_global_timestamp - locked_at;
    }

    // --- SEGÉDFÜGGVÉNY: lock megszerzése ---
    // beállítja a lock_owner-t és a lock_time-t
    action acquire_lock() {
        lock_owner.write(hdr.mem.address, hdr.ethernet.srcAddr);
        lock_time.write(hdr.mem.address, standard_metadata.ingress_global_timestamp);
    }

    // --- SEGÉDFÜGGVÉNY: lock feloldása ---
    action release_lock() {
        lock_owner.write(hdr.mem.address, 0);
        lock_time.write(hdr.mem.address, 0);
    }

    action send_back() {
        bit<48> tmp;
        tmp = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = hdr.ethernet.srcAddr;
        hdr.ethernet.srcAddr = tmp;
        standard_metadata.egress_spec = standard_metadata.ingress_port;
    }

    action read() {
        memory.read(mem_value, hdr.mem.address);
        hdr.mem.value = mem_value;
        hdr.mem.status = STATUS_OK;
        send_back();
    }

    action write() {
        lock_owner.read(owner, hdr.mem.address);

        if (owner == 0) {
            // szabad: mi szerezzük meg a lockot és írunk
            acquire_lock();
            memory.write(hdr.mem.address, hdr.mem.value);
            hdr.mem.status = STATUS_OK;
            send_back();
        } else if (owner == hdr.ethernet.srcAddr) {
            // mi vagyunk a tulajdonos: írhatunk
            memory.write(hdr.mem.address, hdr.mem.value);
            hdr.mem.status = STATUS_OK;
            send_back();
        } else {
            // valaki más a tulajdonos – megnézzük lejárt-e
            check_timeout();
            if (elapsed >= LOCK_TIMEOUT) {
                // lejárt: feloldjuk a régi lockot, mi szerezzük meg és írunk
                acquire_lock();
                memory.write(hdr.mem.address, hdr.mem.value);
                hdr.mem.status = STATUS_OK;
                send_back();
            } else {
                // még érvényes lock: visszautasítjuk
                hdr.mem.status = STATUS_LOCKED;
                send_back();
            }
        }
    }

    action lock() {
        lock_owner.read(owner, hdr.mem.address);

        if (owner == 0) {
            // szabad: mi szerezzük meg a lockot
            acquire_lock();
            hdr.mem.status = STATUS_OK;
            send_back();
        } else if (owner == hdr.ethernet.srcAddr) {
            // már mi vagyunk a tulajdonos: idempotens, OK
            hdr.mem.status = STATUS_OK;
            send_back();
        } else {
            // valaki más a tulajdonos – megnézzük lejárt-e
            check_timeout();
            if (elapsed >= LOCK_TIMEOUT) {
                // lejárt: feloldjuk a régi lockot, mi szerezzük meg
                acquire_lock();
                hdr.mem.status = STATUS_OK;
                send_back();
            } else {
                // még érvényes lock: visszautasítjuk
                hdr.mem.status = STATUS_LOCKED;
                send_back();
            }
        }
    }

    action unlock() {
        lock_owner.read(owner, hdr.mem.address);

        if (owner == hdr.ethernet.srcAddr) {
            // mi vagyunk a tulajdonos: feloldjuk a lockot
            release_lock();
            hdr.mem.status = STATUS_OK;
            send_back();
        } else {
            // nem mi vagyunk a tulajdonos: hiba
            hdr.mem.status = STATUS_ERROR;
            send_back();
        }
    }

    apply {
        // ha nincs mem header, dobjuk el a csomagot
        if (!hdr.mem.isValid()) {
            mark_to_drop(standard_metadata);
            return;
        }
        // --- READ ---
        if (hdr.mem.opcode == OPCODE_READ) {
            read();
        }
        // --- WRITE ---
        else if (hdr.mem.opcode == OPCODE_WRITE) {
            write();
        }
        // --- LOCK ---
        else if (hdr.mem.opcode == OPCODE_LOCK) {
            lock();
        }
        // --- UNLOCK ---
        else if (hdr.mem.opcode == OPCODE_UNLOCK) {
            unlock();
        }
        // --- ISMERETLEN OPCODE ---
        else {
            mark_to_drop(standard_metadata);
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata) {
    apply { }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply { }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers_t hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.mem);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
