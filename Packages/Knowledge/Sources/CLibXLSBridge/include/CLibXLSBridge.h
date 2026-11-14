// Swift-facing module for the vendored libxls (A-M6-10): re-exports upstream's public API (xls.h) plus two
// accessors Swift cannot spell over libxls's nested anonymous-array structs. Used only by XLSAdapter (M6.T07).
#ifndef ANTICHAT_CLIBXLS_BRIDGE_H
#define ANTICHAT_CLIBXLS_BRIDGE_H
#include "../../../../../Vendor/libxls@93f1ad5/include/xls.h"

/// Number format code of the XF record a cell uses (0 when out of range).
unsigned short acx_xls_cell_format(xlsWorkBook *wb, unsigned short xf);
/// Custom number-format string for a format code, or NULL for a built-in code.
const char *acx_xls_format_string(xlsWorkBook *wb, unsigned short format);
/// 1 when the workbook uses the 1904 date system.
int acx_xls_is1904(xlsWorkBook *wb);
#endif
