#!/bin/bash
# Sync kam.toml to module.prop and update.json
# This hook generates:
# - module.prop in module directory ($KAM_MODULE_ROOT/module.prop)
# - update.json in project root ($KAM_PROJECT_ROOT/update.json)

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command kam "kam CLI not found; cannot export files"

log_info "Syncing kam.toml to module.prop and update.json (via 'kam export')..."

# Check if required KAM environment variables are set
if [ -z "$KAM_MODULE_ID" ] || [ -z "$KAM_MODULE_VERSION" ] || [ -z "$KAM_MODULE_VERSION_CODE" ]; then
    log_error "Required KAM_MODULE_* environment variables are not set"
    exit 1
fi

# Skip template modules (modules with id ending in _template)
case "$KAM_MODULE_ID" in
    *_template)
        log_info "Skipping template module: $KAM_MODULE_ID"
        exit 0
        ;;
esac

# Determine file paths
# module.prop goes to module directory
MODULE_PROP_PATH="${KAM_MODULE_ROOT}/module.prop"
# update.json goes to project root directory
UPDATE_JSON_PATH="${KAM_PROJECT_ROOT}/update.json"
# module.json path
MODULE_JSON_PATH="${KAM_PROJECT_ROOT}/module.json"

# Check if the module root directory exists
if [ ! -d "$KAM_MODULE_ROOT" ]; then
    log_warn "Module directory does not exist: $KAM_MODULE_ROOT"
    log_info "Attempting to create directory..."
    mkdir -p "$KAM_MODULE_ROOT" || {
        log_error "Failed to create directory: $KAM_MODULE_ROOT"
        exit 1
    }
fi

###########################################
# Sync module.prop using kam export (fallback to manual generation)
###########################################
log_info "Exporting module.prop using 'kam export' to: $MODULE_PROP_PATH"
if kam export prop "$MODULE_PROP_PATH"; then
    log_success "module.prop exported via 'kam export' to: $MODULE_PROP_PATH"
else
    log_error "'kam export' failed for module.prop; aborting"
    exit 1
fi

###########################################
# Sync update.json using kam export (fallback to manual generation)
###########################################
log_info "Exporting update.json using 'kam export' to: $UPDATE_JSON_PATH"
if kam export update "$UPDATE_JSON_PATH"; then
    log_success "update.json exported via 'kam export' to: $UPDATE_JSON_PATH"
else
    log_error "'kam export' failed for update.json; aborting"
    exit 1
fi

###########################################
# Sync module.json using kam export (fallback to manual generation)
###########################################
log_info "Exporting module.json using 'kam export' to: $MODULE_JSON_PATH"
if kam export json "$MODULE_JSON_PATH"; then
    log_success "module.json exported via 'kam export' to: $MODULE_JSON_PATH"
else
    log_error "'kam export' failed for update.json; aborting"
    exit 1
fi

# update.json is exported above exclusively using 'kam export'

log_success "kam.toml → module.prop & update.json sync completed"
