use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::App;

pub(crate) fn command_text_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    compact_command_output(&command_text_full_timeout(program, args, timeout))
}

pub(crate) fn command_text_full_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => return format!("{program} not available: {err}"),
    };
    let stdout_reader = child.stdout.take().map(spawn_output_reader);
    let stderr_reader = child.stderr.take().map(spawn_output_reader);
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return match join_output_readers(stdout_reader, stderr_reader) {
                    Ok((stdout, stderr)) => merge_command_output(&stdout, &stderr),
                    Err(err) => err,
                };
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(40)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = join_output_readers(stdout_reader, stderr_reader);
                return format!("timeout after {}ms", timeout.as_millis());
            }
            Err(err) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = join_output_readers(stdout_reader, stderr_reader);
                return format!("wait failed: {err}");
            }
        }
    }
}

type OutputReader = thread::JoinHandle<std::io::Result<Vec<u8>>>;

fn spawn_output_reader<R>(mut reader: R) -> OutputReader
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut output = Vec::new();
        reader.read_to_end(&mut output)?;
        Ok(output)
    })
}

fn join_output_readers(
    stdout: Option<OutputReader>,
    stderr: Option<OutputReader>,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let stdout = join_output_reader(stdout, "stdout");
    let stderr = join_output_reader(stderr, "stderr");
    match (stdout, stderr) {
        (Ok(stdout), Ok(stderr)) => Ok((stdout, stderr)),
        (Err(err), _) | (_, Err(err)) => Err(err),
    }
}

fn join_output_reader(reader: Option<OutputReader>, name: &str) -> Result<Vec<u8>, String> {
    match reader {
        Some(reader) => match reader.join() {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(err)) => Err(format!("read failed: {name}: {err}")),
            Err(_) => Err(format!("read failed: {name} reader thread panicked")),
        },
        None => Err(format!("read failed: {name} pipe unavailable")),
    }
}

pub(crate) fn clean_lines(path: PathBuf) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

pub(crate) fn first_clean_line(path: PathBuf) -> String {
    clean_lines(path).into_iter().next().unwrap_or_default()
}

pub(crate) fn write_text_file(path: PathBuf, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(&path, text).map_err(|err| format!("write {}: {err}", path.display()))
}

pub(crate) fn clear_node_cache(app: &App) {
    let _ = fs::remove_file(app.moddir.join(".tmp/magicnet-node-list.cache"));
}

pub(crate) fn read_kv(path: PathBuf) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        map.insert(key.trim().to_string(), value);
    }
    map
}

pub(crate) fn write_kv(path: PathBuf, values: &[(&str, String)]) -> Result<(), String> {
    let text = values
        .iter()
        .map(|(key, value)| format!("{key}={value}\n"))
        .collect::<String>();
    write_text_file(path, &text)
}

fn merge_command_output(stdout: &[u8], stderr: &[u8]) -> String {
    let mut text = String::from_utf8_lossy(stdout).trim().to_string();
    let err = String::from_utf8_lossy(stderr).trim().to_string();
    if text.is_empty() {
        text = err;
    } else if !err.is_empty() {
        text.push_str("; ");
        text.push_str(&err);
    }
    text
}

fn compact_command_output(output: &str) -> String {
    output
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no output")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{
        command_text_full_timeout, command_text_timeout, compact_command_output,
        merge_command_output,
    };

    #[test]
    fn full_output_preserves_trimmed_stdout_and_appends_trimmed_stderr() {
        assert_eq!(
            merge_command_output(b"  first\nsecond  \n", b"  warning\n  "),
            "first\nsecond; warning"
        );
    }

    #[test]
    fn compact_output_keeps_the_last_nonempty_line() {
        assert_eq!(
            compact_command_output("first\n\n  final; warning  \n"),
            "final; warning"
        );
    }

    #[test]
    fn compact_output_keeps_timeout_errors_byte_for_byte() {
        assert_eq!(
            compact_command_output("timeout after 5000ms"),
            "timeout after 5000ms"
        );
    }

    #[test]
    fn full_and_compact_helpers_share_process_output_semantics() {
        let args = ["-c", "printf 'first\\nsecond'; printf 'warning' >&2"];
        let full = command_text_full_timeout("sh", &args, Duration::from_secs(1));
        let compact = command_text_timeout("sh", &args, Duration::from_secs(1));

        assert_eq!(
            (full, compact),
            (
                "first\nsecond; warning".to_string(),
                "second; warning".to_string()
            )
        );
    }

    #[test]
    fn full_output_drains_more_than_pipe_capacity_without_waiting_for_timeout() {
        let script = "chunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 8192 ]; do printf %s \"$chunk\"; i=$((i + 1)); done";
        let started = Instant::now();
        let output = command_text_full_timeout("sh", &["-c", script], Duration::from_secs(8));

        assert_eq!(
            (output.len(), started.elapsed() < Duration::from_secs(4)),
            (32 * 8192, true)
        );
    }

    #[test]
    fn builtin_infinite_loop_times_out_promptly_and_exactly() {
        let started = Instant::now();
        let output = command_text_full_timeout(
            "sh",
            &["-c", "while :; do :; done"],
            Duration::from_millis(120),
        );

        assert_eq!(
            (output, started.elapsed() < Duration::from_secs(2)),
            ("timeout after 120ms".to_string(), true)
        );
    }
}
