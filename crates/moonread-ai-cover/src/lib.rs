//! AI cover extraction for the host's already authorized response bodies.
mod cover_page;

use std::{ptr, slice, str};

#[repr(C)]
pub struct MoonreadCoverBytes {
    data: *const u8,
    len: usize,
}

impl MoonreadCoverBytes {
    unsafe fn borrowed(&self) -> &[u8] {
        if self.data.is_null() {
            &[]
        } else {
            unsafe { slice::from_raw_parts(self.data, self.len) }
        }
    }
}

/// Extract a JSON array of image URLs. String inputs are UTF-8; null means absent.
///
/// # Safety
/// Non-null input pointers must describe readable byte ranges for this call.
/// The returned allocation must be released with `moonread_ai_cover_release`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn moonread_ai_cover_extract(
    body: MoonreadCoverBytes,
    response_url: MoonreadCoverBytes,
    charset: MoonreadCoverBytes,
    title: MoonreadCoverBytes,
) -> MoonreadCoverBytes {
    let urls = unsafe {
        cover_page::extract_page_images(
            body.borrowed().to_vec(),
            String::from_utf8_lossy(response_url.borrowed()).into_owned(),
            str::from_utf8(charset.borrowed()).ok().map(str::to_owned),
            str::from_utf8(title.borrowed()).ok().map(str::to_owned),
        )
    };
    let output = serde_json::to_vec(&urls)
        .expect("strings always serialize")
        .into_boxed_slice();
    let len = output.len();
    MoonreadCoverBytes {
        data: Box::into_raw(output).cast(),
        len,
    }
}

/// # Safety
/// `output` must be the still-live result of `moonread_ai_cover_extract`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn moonread_ai_cover_release(output: MoonreadCoverBytes) {
    let raw = ptr::slice_from_raw_parts_mut(output.data.cast_mut(), output.len);
    drop(unsafe { Box::from_raw(raw) });
}
