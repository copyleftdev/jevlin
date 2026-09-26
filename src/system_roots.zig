//! Windows root enumeration must release the current certificate on early exit.
//! Zig 0.16.0's Bundle.rescanWindows omits this cleanup on allocation failure.
const std = @import("std");

pub fn load(bundle: *std.crypto.Certificate.Bundle, allocator: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp) !void {
    if (@import("builtin").os.tag != .windows) return bundle.rescan(allocator, io, now);
    const w = std.os.windows;
    const api = w.crypt32;
    bundle.bytes.clearRetainingCapacity();
    bundle.map.clearRetainingCapacity();
    const store_name = std.unicode.utf8ToUtf16LeStringLiteral("ROOT");
    const store = api.CertOpenSystemStoreW(.NULL, store_name) orelse return error.CertificateStoreOpenFailed;
    defer {
        const closed = api.CertCloseStore(store, .{ .CHECK = true });
        std.debug.assert(closed.toBool());
    }
    var current = api.CertEnumCertificatesInStore(store, null);
    // Enumeration frees the previous context when advancing. On an early return
    // we still own current; release it BEFORE closing the store (LIFO defers).
    defer if (current) |certificate| {
        const freed = api.CertFreeCertificateContext(certificate);
        std.debug.assert(freed.toBool());
    };
    while (current) |certificate| {
        const offset = std.math.cast(u32, bundle.bytes.items.len) orelse return error.CertificateBundleTooLarge;
        try bundle.bytes.appendSlice(allocator, certificate.pbCertEncoded[0..certificate.cbCertEncoded]);
        try bundle.parseCert(allocator, offset, now.toSeconds());
        current = api.CertEnumCertificatesInStore(store, certificate);
    }
    switch (w.GetLastError()) {
        .CRYPT_E_NOT_FOUND, .NO_MORE_FILES => {},
        else => return error.CertificateStoreEnumerationFailed,
    }
}
