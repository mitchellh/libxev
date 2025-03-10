//! These are copied from Zig's stdlib as of Zig 0.14 because
//! they are no longer exported. This is probably going to be
//! fixed in the future: https://github.com/ziglang/zig/pull/21218
const std = @import("std");

pub const MACH_SEND_MSG = 0x00000001;
pub const MACH_RCV_MSG = 0x00000002;

pub const MACH_SEND_TIMEOUT = 0x00000010;
pub const MACH_SEND_OVERRIDE = 0x00000020;
pub const MACH_SEND_INTERRUPT = 0x00000040;
pub const MACH_SEND_NOTIFY = 0x00000080;
pub const MACH_SEND_ALWAYS = 0x00010000;
pub const MACH_SEND_FILTER_NONFATAL = 0x00010000;
pub const MACH_SEND_TRAILER = 0x00020000;
pub const MACH_SEND_NOIMPORTANCE = 0x00040000;
pub const MACH_SEND_NODENAP = MACH_SEND_NOIMPORTANCE;
pub const MACH_SEND_IMPORTANCE = 0x00080000;
pub const MACH_SEND_SYNC_OVERRIDE = 0x00100000;
pub const MACH_SEND_PROPAGATE_QOS = 0x00200000;
pub const MACH_SEND_SYNC_USE_THRPRI = MACH_SEND_PROPAGATE_QOS;
pub const MACH_SEND_KERNEL = 0x00400000;
pub const MACH_SEND_SYNC_BOOTSTRAP_CHECKIN = 0x00800000;

pub const MACH_RCV_TIMEOUT = 0x00000100;
pub const MACH_RCV_NOTIFY = 0x00000000;
pub const MACH_RCV_INTERRUPT = 0x00000400;
pub const MACH_RCV_VOUCHER = 0x00000800;
pub const MACH_RCV_OVERWRITE = 0x00000000;
pub const MACH_RCV_GUARDED_DESC = 0x00001000;
pub const MACH_RCV_SYNC_WAIT = 0x00004000;
pub const MACH_RCV_SYNC_PEEK = 0x00008000;

pub const MACH_PORT_NULL: mach_port_t = 0;
pub const MACH_MSG_TIMEOUT_NONE: mach_msg_timeout_t = 0;

pub const natural_t = c_uint;
pub const integer_t = c_int;
pub const mach_port_t = c_uint;
pub const mach_port_name_t = natural_t;
pub const mach_msg_bits_t = c_uint;
pub const mach_msg_id_t = integer_t;
pub const mach_msg_type_number_t = natural_t;
pub const mach_msg_type_name_t = c_uint;
pub const mach_msg_option_t = integer_t;
pub const mach_msg_size_t = natural_t;
pub const mach_msg_timeout_t = natural_t;
pub const mach_msg_return_t = std.c.kern_return_t;

pub const mach_msg_header_t = extern struct {
    msgh_bits: mach_msg_bits_t,
    msgh_size: mach_msg_size_t,
    msgh_remote_port: mach_port_t,
    msgh_local_port: mach_port_t,
    msgh_voucher_port: mach_port_name_t,
    msgh_id: mach_msg_id_t,
};

pub extern "c" fn mach_msg(
    msg: ?*mach_msg_header_t,
    option: mach_msg_option_t,
    send_size: mach_msg_size_t,
    rcv_size: mach_msg_size_t,
    rcv_name: mach_port_name_t,
    timeout: mach_msg_timeout_t,
    notify: mach_port_name_t,
) std.c.kern_return_t;

pub fn getKernError(err: std.c.kern_return_t) KernE {
    return @as(KernE, @enumFromInt(@as(u32, @truncate(@as(usize, @intCast(err))))));
}

/// Kernel return values
pub const KernE = enum(u32) {
    SUCCESS = 0,

    /// Specified address is not currently valid
    INVALID_ADDRESS = 1,

    /// Specified memory is valid, but does not permit the
    /// required forms of access.
    PROTECTION_FAILURE = 2,

    /// The address range specified is already in use, or
    /// no address range of the size specified could be
    /// found.
    NO_SPACE = 3,

    /// The function requested was not applicable to this
    /// type of argument, or an argument is invalid
    INVALID_ARGUMENT = 4,

    /// The function could not be performed.  A catch-all.
    FAILURE = 5,

    /// A system resource could not be allocated to fulfill
    /// this request.  This failure may not be permanent.
    RESOURCE_SHORTAGE = 6,

    /// The task in question does not hold receive rights
    /// for the port argument.
    NOT_RECEIVER = 7,

    /// Bogus access restriction.
    NO_ACCESS = 8,

    /// During a page fault, the target address refers to a
    /// memory object that has been destroyed.  This
    /// failure is permanent.
    MEMORY_FAILURE = 9,

    /// During a page fault, the memory object indicated
    /// that the data could not be returned.  This failure
    /// may be temporary; future attempts to access this
    /// same data may succeed, as defined by the memory
    /// object.
    MEMORY_ERROR = 10,

    /// The receive right is already a member of the portset.
    ALREADY_IN_SET = 11,

    /// The receive right is not a member of a port set.
    NOT_IN_SET = 12,

    /// The name already denotes a right in the task.
    NAME_EXISTS = 13,

    /// The operation was aborted.  Ipc code will
    /// catch this and reflect it as a message error.
    ABORTED = 14,

    /// The name doesn't denote a right in the task.
    INVALID_NAME = 15,

    /// Target task isn't an active task.
    INVALID_TASK = 16,

    /// The name denotes a right, but not an appropriate right.
    INVALID_RIGHT = 17,

    /// A blatant range error.
    INVALID_VALUE = 18,

    /// Operation would overflow limit on user-references.
    UREFS_OVERFLOW = 19,

    /// The supplied (port) capability is improper.
    INVALID_CAPABILITY = 20,

    /// The task already has send or receive rights
    /// for the port under another name.
    RIGHT_EXISTS = 21,

    /// Target host isn't actually a host.
    INVALID_HOST = 22,

    /// An attempt was made to supply "precious" data
    /// for memory that is already present in a
    /// memory object.
    MEMORY_PRESENT = 23,

    /// A page was requested of a memory manager via
    /// memory_object_data_request for an object using
    /// a MEMORY_OBJECT_COPY_CALL strategy, with the
    /// VM_PROT_WANTS_COPY flag being used to specify
    /// that the page desired is for a copy of the
    /// object, and the memory manager has detected
    /// the page was pushed into a copy of the object
    /// while the kernel was walking the shadow chain
    /// from the copy to the object. This error code
    /// is delivered via memory_object_data_error
    /// and is handled by the kernel (it forces the
    /// kernel to restart the fault). It will not be
    /// seen by users.
    MEMORY_DATA_MOVED = 24,

    /// A strategic copy was attempted of an object
    /// upon which a quicker copy is now possible.
    /// The caller should retry the copy using
    /// vm_object_copy_quickly. This error code
    /// is seen only by the kernel.
    MEMORY_RESTART_COPY = 25,

    /// An argument applied to assert processor set privilege
    /// was not a processor set control port.
    INVALID_PROCESSOR_SET = 26,

    /// The specified scheduling attributes exceed the thread's
    /// limits.
    POLICY_LIMIT = 27,

    /// The specified scheduling policy is not currently
    /// enabled for the processor set.
    INVALID_POLICY = 28,

    /// The external memory manager failed to initialize the
    /// memory object.
    INVALID_OBJECT = 29,

    /// A thread is attempting to wait for an event for which
    /// there is already a waiting thread.
    ALREADY_WAITING = 30,

    /// An attempt was made to destroy the default processor
    /// set.
    DEFAULT_SET = 31,

    /// An attempt was made to fetch an exception port that is
    /// protected, or to abort a thread while processing a
    /// protected exception.
    EXCEPTION_PROTECTED = 32,

    /// A ledger was required but not supplied.
    INVALID_LEDGER = 33,

    /// The port was not a memory cache control port.
    INVALID_MEMORY_CONTROL = 34,

    /// An argument supplied to assert security privilege
    /// was not a host security port.
    INVALID_SECURITY = 35,

    /// thread_depress_abort was called on a thread which
    /// was not currently depressed.
    NOT_DEPRESSED = 36,

    /// Object has been terminated and is no longer available
    TERMINATED = 37,

    /// Lock set has been destroyed and is no longer available.
    LOCK_SET_DESTROYED = 38,

    /// The thread holding the lock terminated before releasing
    /// the lock
    LOCK_UNSTABLE = 39,

    /// The lock is already owned by another thread
    LOCK_OWNED = 40,

    /// The lock is already owned by the calling thread
    LOCK_OWNED_SELF = 41,

    /// Semaphore has been destroyed and is no longer available.
    SEMAPHORE_DESTROYED = 42,

    /// Return from RPC indicating the target server was
    /// terminated before it successfully replied
    RPC_SERVER_TERMINATED = 43,

    /// Terminate an orphaned activation.
    RPC_TERMINATE_ORPHAN = 44,

    /// Allow an orphaned activation to continue executing.
    RPC_CONTINUE_ORPHAN = 45,

    /// Empty thread activation (No thread linked to it)
    NOT_SUPPORTED = 46,

    /// Remote node down or inaccessible.
    NODE_DOWN = 47,

    /// A signalled thread was not actually waiting.
    NOT_WAITING = 48,

    /// Some thread-oriented operation (semaphore_wait) timed out
    OPERATION_TIMED_OUT = 49,

    /// During a page fault, indicates that the page was rejected
    /// as a result of a signature check.
    CODESIGN_ERROR = 50,

    /// The requested property cannot be changed at this time.
    POLICY_STATIC = 51,

    /// The provided buffer is of insufficient size for the requested data.
    INSUFFICIENT_BUFFER_SIZE = 52,

    /// Denied by security policy
    DENIED = 53,

    /// The KC on which the function is operating is missing
    MISSING_KC = 54,

    /// The KC on which the function is operating is invalid
    INVALID_KC = 55,

    /// A search or query operation did not return a result
    NOT_FOUND = 56,

    _,
};

pub fn getMachMsgError(err: mach_msg_return_t) MachMsgE {
    return @as(MachMsgE, @enumFromInt(@as(u32, @truncate(@as(usize, @intCast(err))))));
}

/// Mach msg return values
pub const MachMsgE = enum(u32) {
    SUCCESS = 0x00000000,

    /// Thread is waiting to send.  (Internal use only.)
    SEND_IN_PROGRESS = 0x10000001,
    /// Bogus in-line data.
    SEND_INVALID_DATA = 0x10000002,
    /// Bogus destination port.
    SEND_INVALID_DEST = 0x10000003,
    ///  Message not sent before timeout expired.
    SEND_TIMED_OUT = 0x10000004,
    ///  Bogus voucher port.
    SEND_INVALID_VOUCHER = 0x10000005,
    ///  Software interrupt.
    SEND_INTERRUPTED = 0x10000007,
    ///  Data doesn't contain a complete message.
    SEND_MSG_TOO_SMALL = 0x10000008,
    ///  Bogus reply port.
    SEND_INVALID_REPLY = 0x10000009,
    ///  Bogus port rights in the message body.
    SEND_INVALID_RIGHT = 0x1000000a,
    ///  Bogus notify port argument.
    SEND_INVALID_NOTIFY = 0x1000000b,
    ///  Invalid out-of-line memory pointer.
    SEND_INVALID_MEMORY = 0x1000000c,
    ///  No message buffer is available.
    SEND_NO_BUFFER = 0x1000000d,
    ///  Send is too large for port
    SEND_TOO_LARGE = 0x1000000e,
    ///  Invalid msg-type specification.
    SEND_INVALID_TYPE = 0x1000000f,
    ///  A field in the header had a bad value.
    SEND_INVALID_HEADER = 0x10000010,
    ///  The trailer to be sent does not match kernel format.
    SEND_INVALID_TRAILER = 0x10000011,
    ///  The sending thread context did not match the context on the dest port
    SEND_INVALID_CONTEXT = 0x10000012,
    ///  compatibility: no longer a returned error
    SEND_INVALID_RT_OOL_SIZE = 0x10000015,
    ///  The destination port doesn't accept ports in body
    SEND_NO_GRANT_DEST = 0x10000016,
    ///  Message send was rejected by message filter
    SEND_MSG_FILTERED = 0x10000017,

    ///  Thread is waiting for receive.  (Internal use only.)
    RCV_IN_PROGRESS = 0x10004001,
    ///  Bogus name for receive port/port-set.
    RCV_INVALID_NAME = 0x10004002,
    ///  Didn't get a message within the timeout value.
    RCV_TIMED_OUT = 0x10004003,
    ///  Message buffer is not large enough for inline data.
    RCV_TOO_LARGE = 0x10004004,
    ///  Software interrupt.
    RCV_INTERRUPTED = 0x10004005,
    ///  compatibility: no longer a returned error
    RCV_PORT_CHANGED = 0x10004006,
    ///  Bogus notify port argument.
    RCV_INVALID_NOTIFY = 0x10004007,
    ///  Bogus message buffer for inline data.
    RCV_INVALID_DATA = 0x10004008,
    ///  Port/set was sent away/died during receive.
    RCV_PORT_DIED = 0x10004009,
    ///  compatibility: no longer a returned error
    RCV_IN_SET = 0x1000400a,
    ///  Error receiving message header.  See special bits.
    RCV_HEADER_ERROR = 0x1000400b,
    ///  Error receiving message body.  See special bits.
    RCV_BODY_ERROR = 0x1000400c,
    ///  Invalid msg-type specification in scatter list.
    RCV_INVALID_TYPE = 0x1000400d,
    ///  Out-of-line overwrite region is not large enough
    RCV_SCATTER_SMALL = 0x1000400e,
    ///  trailer type or number of trailer elements not supported
    RCV_INVALID_TRAILER = 0x1000400f,
    ///  Waiting for receive with timeout. (Internal use only.)
    RCV_IN_PROGRESS_TIMED = 0x10004011,
    ///  invalid reply port used in a STRICT_REPLY message
    RCV_INVALID_REPLY = 0x10004012,
};
