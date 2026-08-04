-- This manifest is intentionally explicit. Adding a test file does not execute it
-- until a reviewer also adds its module name here.

return {
    'wzx.tests.test_manifest_and_path_guard',
    'wzx.tests.test_result_and_error_codes',
    'wzx.tests.test_runtime_id_and_ordered',
    'wzx.tests.test_sha256',
    'wzx.tests.test_codec_and_receipt_hash',
    'wzx.tests.test_rng_and_seed',
    'wzx.tests.test_ports_and_fakes',
    'wzx.tests.test_events_and_table_shape',
    'wzx.tests.test_save_and_contracts',
    'wzx.tests.test_foundation_contracts',
    'wzx.tests.test_config_registries',
    'wzx.tests.test_character_domain',
    'wzx.tests.test_bootstrap',
}
