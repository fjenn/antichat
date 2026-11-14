// AntiChat-owned build configuration for the vendored libxls (Vendor/libxls@93f1ad5, A-M6-10). Upstream generates
// this file with autotools; these are the values its configure.ac finds on macOS 15+ (iconv in libSystem/libiconv,
// <xlocale.h>, wcstombs_l). Kept outside Vendor/ so the vendored copy stays byte-identical to upstream.
#ifndef ANTICHAT_LIBXLS_CONFIG_H
#define ANTICHAT_LIBXLS_CONFIG_H
#define HAVE_ICONV 1
#define ICONV_CONST
#define HAVE_XLOCALE_H 1
#define HAVE_WCSTOMBS_L 1
#define HAVE_STRDUP 1
#define HAVE_WCHAR_H 1
#define PACKAGE_VERSION "1.6.4"
#define LIBXLS_MAJOR_VERSION 1
#define LIBXLS_MINOR_VERSION 6
#define LIBXLS_MICRO_VERSION 4
#endif
