/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 NuxFX contributors */
/* Capture one X11 window (by id) to a PPM file. Only the given window is read. */
#include <stdio.h>
#include <stdlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: xcap WINDOW_ID OUT.ppm\n"); return 1; }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "no display\n"); return 1; }
    Window w = (Window)strtoul(argv[1], NULL, 0);
    XWindowAttributes wa;
    if (!XGetWindowAttributes(dpy, w, &wa)) { fprintf(stderr, "bad window\n"); return 1; }
    XImage *img = XGetImage(dpy, w, 0, 0, wa.width, wa.height, AllPlanes, ZPixmap);
    if (!img) { fprintf(stderr, "XGetImage failed\n"); return 1; }
    FILE *f = fopen(argv[2], "wb");
    fprintf(f, "P6\n%d %d\n255\n", img->width, img->height);
    for (int y = 0; y < img->height; y++)
        for (int x = 0; x < img->width; x++) {
            unsigned long p = XGetPixel(img, x, y);
            unsigned char rgb[3] = { (p >> 16) & 255, (p >> 8) & 255, p & 255 };
            fwrite(rgb, 1, 3, f);
        }
    fclose(f);
    XDestroyImage(img);
    XCloseDisplay(dpy);
    printf("%dx%d\n", wa.width, wa.height);
    return 0;
}
