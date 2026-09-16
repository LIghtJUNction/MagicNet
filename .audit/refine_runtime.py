from pathlib import Path
root=Path.cwd()
p=root/'crates/magicnet-cli/src/state.rs'; s=p.read_text()
a=s.index('fn read_json(path:'); b=s.index('\nfn regular_nonempty',a)
helper=s[a:b].replace('fn read_json(', 'pub(crate) fn read_json_file_bounded(').replace('Option<Value>', 'Option<serde_json::Value>')
s=s[:a]+s[b+1:]
s=s.replace('use std::io::Read;\n','').replace('use std::os::unix::fs::OpenOptionsExt;\n','')
s=s.replace('use crate::diagnostics::supervisor_pid;', 'use crate::diagnostics::supervisor_pid;\nuse crate::utils::read_json_file_bounded as read_json;')
p.write_text(s)
p=root/'crates/magicnet-cli/src/utils.rs';s=p.read_text().replace('{MetadataExt, PermissionsExt}', '{MetadataExt, OpenOptionsExt, PermissionsExt}')
pos=s.index('fn close_raw_fd')
s=s[:pos]+'''/// Read a regular JSON file with a limit enforced on the descriptor, not a
/// racy path stat. Never follow symlinks or block opening a FIFO as config.
'''+helper+'\n\n'+s[pos:];p.write_text(s)
p=root/'crates/magicnet-cli/src/app.rs';s=p.read_text().replace('use std::fs;\n','',1).replace('use serde_json::Value;\n','use crate::utils::read_json_file_bounded;\n')
s=s.replace('''    let config = fs::read(moddir.join(SINGBOX_CONFIG)).ok()?;
    let config: Value = serde_json::from_slice(&config).ok()?;''','''    let config = read_json_file_bounded(&moddir.join(SINGBOX_CONFIG), 4 * 1024 * 1024)?;''')
pos=s.rfind('\n}')
s=s[:pos]+'''
    #[test]
    fn controller_observation_rejects_fifo_symlink_and_oversized_config() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let root = fixture_root();
        let path = root.join(SINGBOX_CONFIG);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let fifo = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert_eq!(local_api_from_config(&root), None);
        fs::remove_file(&path).unwrap();
        let target = root.join("controller.json");
        fs::write(&target, r#"{"experimental":{"clash_api":{"external_controller":"127.0.0.1:19090"}}}"#).unwrap();
        symlink(&target, &path).unwrap();
        assert_eq!(local_api_from_config(&root), None);
        fs::remove_file(&path).unwrap();
        let oversized = fs::File::create(&path).unwrap();
        oversized.set_len(4 * 1024 * 1024 + 1).unwrap();
        assert_eq!(local_api_from_config(&root), None);
        fs::remove_dir_all(root).unwrap();
    }
'''+s[pos:]
s=s.replace('api_from_controller, infer_moddir_from_exe, is_loopback_http_api, local_api_from_config,','api_from_controller, infer_moddir_from_exe, is_loopback_http_api, local_api_from_config,\n        SINGBOX_CONFIG,')
p.write_text(s)
p=root/'crates/magicnet-cli/src/machine.rs';s=p.read_text();s=s.replace('''    let effective = fs::read_to_string(app.moddir.join(SINGBOX_CONFIG))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());''','''    let effective = crate::utils::read_json_file_bounded(
        &app.moddir.join(SINGBOX_CONFIG),
        4 * 1024 * 1024,
    );''');p.write_text(s)
p=root/'scripts/package-smoke.sh';s=p.read_text().replace("    'lib/magicnet/primitives.sh' \\\n", "    'lib/magicnet/primitives.sh' \\\
    'lib/magicnet/api.sh' \\\n");p.write_text(s)
p=root/'scripts/test-host.sh';s=p.read_text().replace('check bash scripts/test-module-entrypoints.sh\n','check bash scripts/test-module-entrypoints.sh\ncheck bash scripts/test-api-endpoint.sh\n');p.write_text(s)
