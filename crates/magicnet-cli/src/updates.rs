use crate::App;
use std::process::Command;

fn validate(args: &[String]) -> Result<(), String> {
    let valid = match args {
        [action] => matches!(action.as_str(), "status" | "check" | "apply"),
        [action, enabled, hours, wifi] if action == "configure" => {
            matches!(enabled.as_str(), "0" | "1")
                && matches!(wifi.as_str(), "0" | "1")
                && hours
                    .parse::<u16>()
                    .is_ok_and(|hours| (1..=168).contains(&hours))
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(
            "usage: cli update {status|check|apply|configure <0|1> <hours:1-168> <wifi-only:0|1>}"
                .into(),
        )
    }
}

pub(crate) fn update_cmd(app: &App, args: &[String]) -> Result<(), String> {
    validate(args)?;
    let binary = app.moddir.join("bin/magicnet-components");
    let metadata = std::fs::symlink_metadata(&binary)
        .map_err(|error| format!("component updater unavailable: {error}"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("component updater must be a regular module binary".into());
    }
    // Arguments are a closed vocabulary, passed as argv, never shell text.
    // Keep caller-controlled loader/proxy variables out of privileged updates.
    let status = Command::new(binary)
        .arg("update")
        .args(args)
        .env_clear()
        .env("PATH", "/data/adb/magisk:/system/bin:/system/xbin")
        .env("HOME", "/data/adb")
        .status()
        .map_err(|error| format!("could not start component updater: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("component updater failed: {status}"))
    }
}

#[cfg(test)]
mod tests {
    use super::validate;

    #[test]
    fn only_documented_update_actions_are_accepted() {
        for args in [
            vec!["status"],
            vec!["check"],
            vec!["apply"],
            vec!["configure", "1", "24", "1"],
        ] {
            let args = args.into_iter().map(String::from).collect::<Vec<_>>();
            assert!(validate(&args).is_ok());
        }
        for args in [
            vec!["daemon"],
            vec!["apply", "--module-dir", "/tmp"],
            vec!["configure", "1", "0", "1"],
            vec!["configure", "1", "169", "1"],
            vec!["configure", "1", "24;reboot", "1"],
            vec!["configure", "true", "24", "1"],
        ] {
            let args = args.into_iter().map(String::from).collect::<Vec<_>>();
            assert!(validate(&args).is_err());
        }
    }
}
