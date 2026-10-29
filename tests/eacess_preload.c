/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 AdmiralGDR */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* Test-only. Denies open of paths that contain this marker so a namespaced
   root cannot read a mode 000 file that DAC would still allow. */

static int blocked(const char *path)
{
    return path && strstr(path, "quc-unreadable") != NULL;
}

int open(const char *path, int flags, ...)
{
    static int (*real_open)(const char *, int, ...) = NULL;
    mode_t mode = 0;

    if (!real_open)
        real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (blocked(path)) {
        errno = EACCES;
        return -1;
    }
    if (flags & O_CREAT)
        return real_open(path, flags, mode);
    return real_open(path, flags);
}

int open64(const char *path, int flags, ...)
{
    static int (*real_open64)(const char *, int, ...) = NULL;
    mode_t mode = 0;

    if (!real_open64)
        real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (blocked(path)) {
        errno = EACCES;
        return -1;
    }
    if (flags & O_CREAT)
        return real_open64(path, flags, mode);
    return real_open64(path, flags);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    static int (*real_openat)(int, const char *, int, ...) = NULL;
    mode_t mode = 0;

    if (!real_openat)
        real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (blocked(path)) {
        errno = EACCES;
        return -1;
    }
    if (flags & O_CREAT)
        return real_openat(dirfd, path, flags, mode);
    return real_openat(dirfd, path, flags);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    static int (*real_openat64)(int, const char *, int, ...) = NULL;
    mode_t mode = 0;

    if (!real_openat64)
        real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (blocked(path)) {
        errno = EACCES;
        return -1;
    }
    if (flags & O_CREAT)
        return real_openat64(dirfd, path, flags, mode);
    return real_openat64(dirfd, path, flags);
}

FILE *fopen(const char *path, const char *mode)
{
    static FILE *(*real_fopen)(const char *, const char *) = NULL;

    if (!real_fopen)
        real_fopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    if (blocked(path)) {
        errno = EACCES;
        return NULL;
    }
    return real_fopen(path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    static FILE *(*real_fopen64)(const char *, const char *) = NULL;

    if (!real_fopen64)
        real_fopen64 = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen64");
    if (blocked(path)) {
        errno = EACCES;
        return NULL;
    }
    return real_fopen64(path, mode);
}
