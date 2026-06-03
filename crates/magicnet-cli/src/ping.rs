use std::time::Duration;

use crate::command_text_timeout;

pub(crate) fn pingtest() {
    println!("MagicNet connectivity test");
    println!("timeout=short");
    println!();
    ping_one("Baidu CN", "www.baidu.com", "https://www.baidu.com", None);
    ping_one("Bilibili CN", "www.bilibili.com", "https://www.bilibili.com", None);
    ping_one("Google Global", "www.google.com", "https://www.google.com", Some("http://127.0.0.1:7892"));
    ping_one("ChatGPT Global", "chatgpt.com", "https://chatgpt.com", Some("http://127.0.0.1:7892"));
    ping_one("GitHub Global", "github.com", "https://github.com", Some("http://127.0.0.1:7892"));
}

fn ping_one(name: &str, host: &str, url: &str, proxy: Option<&str>) {
    println!("[{name}]");
    println!("host={host}");
    let ping = command_text_timeout("ping", &["-c", "1", "-W", "1", host], Duration::from_secs(2));
    println!("ping={ping}");
    let mut curl_args = vec!["-fsSI", "--max-time", "2"];
    if let Some(proxy_url) = proxy {
        curl_args.push("-x");
        curl_args.push(proxy_url);
    }
    curl_args.push(url);
    let http = command_text_timeout("curl", &curl_args, Duration::from_secs(3));
    println!("http={http}");
    println!();
}
