//! One JSON document per line, read and written on the service's connections and the app's.

use serde::Serialize;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// No request or answer is longer than this. A control call with pictures in it comes as frames, not
/// as a line.
const LONGEST_LINE: u64 = 64 << 20;

/// The next line, without its newline. `None` at the end, on failure, or for a line that is too long.
pub async fn read<R: AsyncBufRead + Unpin>(reader: &mut R) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    let count = (&mut *reader).take(LONGEST_LINE).read_until(b'\n', &mut line).await.ok()?;
    if count == 0 {
        return None;
    }
    if line.last() == Some(&b'\n') {
        line.pop();
    } else if count as u64 >= LONGEST_LINE {
        return None;
    }
    Some(line)
}

/// Writes `data` and a newline. `false` when the other side has gone.
pub async fn write<W: AsyncWrite + Unpin>(writer: &mut W, data: &[u8]) -> bool {
    let mut message = Vec::with_capacity(data.len() + 1);
    message.extend_from_slice(data);
    message.push(b'\n');
    writer.write_all(&message).await.is_ok()
}

pub async fn write_value<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, value: &T) -> bool {
    match serde_json::to_vec(value) {
        Ok(data) => write(writer, &data).await,
        Err(_) => false,
    }
}
