//! A static library that calls ring's SHA-256, so a build proves that ring's C and
//! assembly compile and link for the target.

/// Writes the SHA-256 of `len` bytes at `data` into the 32 bytes at `out`.
/// Returns 0 on success, 1 when a pointer is null.
///
/// # Safety
/// `data` must point to `len` readable bytes and `out` to 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn ringlib_sha256(data: *const u8, len: usize, out: *mut u8) -> i32 {
    if data.is_null() || out.is_null() {
        return 1;
    }
    let input = core::slice::from_raw_parts(data, len);
    let d = ring::digest::digest(&ring::digest::SHA256, input);
    core::ptr::copy_nonoverlapping(d.as_ref().as_ptr(), out, 32);
    0
}
