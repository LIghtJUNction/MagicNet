# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

[ -f "${MODPATH}/lib/kamfw/.kamfwrc" ] && . "$MODPATH/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'

import rich
import i18n
