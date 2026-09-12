use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use mci_core::ipc::{FRAME_MAGIC, FRAME_VERSION};

fn native_frame(payload: &serde_json::Value) -> Vec<u8> {
    let body = serde_json::to_vec(payload).unwrap();
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&u32::try_from(body.len()).unwrap().to_le_bytes());
    frame.extend_from_slice(&body);
    frame
}

fn read_native_frame(reader: &mut impl std::io::Read) -> serde_json::Value {
    let mut length = [0_u8; 4];
    reader.read_exact(&mut length).unwrap();
    let mut body = vec![0_u8; u32::from_le_bytes(length) as usize];
    reader.read_exact(&mut body).unwrap();
    serde_json::from_slice(&body).unwrap()
}

fn page_message() -> serde_json::Value {
    serde_json::json!({
        "url": "https://example.com/project",
        "title": "Project",
        "text": "synthetic restart evidence",
        "ts_us": 1,
        "tab_id": 7,
        "source_browser": "chrome",
        "incognito": false,
        "frame_url": "https://example.com/project",
        "parent_url": "https://example.com/project",
        "is_top_frame": true,
        "frame_id": 0
    })
}

fn spawn_host(home: &Path) -> Child {
    Command::new(env!("CARGO_BIN_EXE_hippocampus-native-host"))
        .env("HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            return true;
        }
        thread::sleep(Duration::from_millis(10));
    }
    false
}

#[test]
fn socket_loss_exits_the_host_and_a_fresh_host_reconnects_to_the_restarted_agent() {
    let temp = tempfile::Builder::new()
        .prefix("hnh")
        .tempdir_in("/tmp")
        .unwrap();
    let support = temp
        .path()
        .join("Library")
        .join("Application Support")
        .join("MCI");
    std::fs::create_dir_all(&support).unwrap();
    let socket_path = support.join("page_content.sock");

    let first_listener = UnixListener::bind(&socket_path).unwrap();
    let mut first_host = spawn_host(temp.path());
    let (first_agent, _) = first_listener.accept().unwrap();
    first_agent.shutdown(std::net::Shutdown::Both).unwrap();
    drop(first_agent);

    first_host
        .stdin
        .as_mut()
        .unwrap()
        .write_all(&native_frame(&page_message()))
        .unwrap();
    let first_ack = read_native_frame(first_host.stdout.as_mut().unwrap());
    assert_eq!(first_ack["status"], "error");
    assert_eq!(first_ack["reason"], "socket_write");
    if !wait_for_exit(&mut first_host, Duration::from_secs(2)) {
        first_host.kill().unwrap();
        first_host.wait().unwrap();
        panic!("native host kept a stale browser port alive after agent socket loss");
    }

    drop(first_listener);
    std::fs::remove_file(&socket_path).unwrap();
    let second_listener = UnixListener::bind(&socket_path).unwrap();
    let mut second_host = spawn_host(temp.path());
    let (mut second_agent, _) = second_listener.accept().unwrap();
    second_host
        .stdin
        .as_mut()
        .unwrap()
        .write_all(&native_frame(&page_message()))
        .unwrap();

    let mut wire_header = [0_u8; 12];
    second_agent.read_exact(&mut wire_header).unwrap();
    assert_eq!(wire_header[0], FRAME_MAGIC);
    assert_eq!(wire_header[1], FRAME_VERSION);
    assert_eq!(&wire_header[2..4], &0x0050_u16.to_le_bytes());
    let second_ack = read_native_frame(second_host.stdout.as_mut().unwrap());
    assert_eq!(second_ack["status"], "ok");

    drop(second_host.stdin.take());
    assert!(wait_for_exit(&mut second_host, Duration::from_secs(2)));
}
