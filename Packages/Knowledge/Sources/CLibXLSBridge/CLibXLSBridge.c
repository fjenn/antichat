// See include/CLibXLSBridge.h (M6.T07, A-M6-10).
#include "CLibXLSBridge.h"

unsigned short acx_xls_cell_format(xlsWorkBook *wb, unsigned short xf) {
    if (wb == NULL || xf >= wb->xfs.count) return 0;
    return wb->xfs.xf[xf].format;
}

const char *acx_xls_format_string(xlsWorkBook *wb, unsigned short format) {
    if (wb == NULL) return NULL;
    for (DWORD i = 0; i < wb->formats.count; i++) {
        if (wb->formats.format[i].index == format) return wb->formats.format[i].value;
    }
    return NULL;
}

int acx_xls_is1904(xlsWorkBook *wb) { return wb != NULL && wb->is1904 ? 1 : 0; }
