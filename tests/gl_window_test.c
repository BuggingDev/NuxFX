/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 NuxFX contributors */
/* Windows program for run_gl_window_test.sh: a top-level window with an OpenGL child
 * window (how After Effects draws its Composition panel) that is cleared to cyan, with a
 * red triangle on top. It reads the pixels back, so the log shows whether OpenGL itself
 * works; the test script then checks that the child window also reaches the screen.
 * usage: gl_window_test.exe SECONDS */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    if (msg == WM_ERASEBKGND) return 1;
    return DefWindowProcA(hwnd, msg, wparam, lparam);
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 20;
    WNDCLASSA wc;
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "aegnux_gl_window_test";
    wc.hbrBackground = (HBRUSH)GetStockObject(GRAY_BRUSH);
    RegisterClassA(&wc);

    HWND top = CreateWindowA(wc.lpszClassName, "gl window test", WS_POPUP | WS_VISIBLE, 0, 0, 900, 700, NULL, NULL, wc.hInstance, NULL);
    HWND child = CreateWindowA(wc.lpszClassName, "gl", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 100, 100, 640, 360, top, NULL, wc.hInstance, NULL);
    HDC dc = GetDC(child);

    PIXELFORMATDESCRIPTOR pfd;
    memset(&pfd, 0, sizeof pfd);
    pfd.nSize = sizeof pfd;
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    int format = ChoosePixelFormat(dc, &pfd);
    if (!format || !SetPixelFormat(dc, format, &pfd)) { printf("no pixel format\n"); return 2; }
    HGLRC rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { printf("no OpenGL context\n"); return 2; }
    printf("GL_RENDERER %s\nGL_VERSION %s\n", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
    fflush(stdout);

    DWORD start = GetTickCount();
    int frame = 0;
    while (GetTickCount() - start < (DWORD)seconds * 1000) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        glViewport(0, 0, 640, 360);
        glClearColor(0.f, 1.f, 1.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        glMatrixMode(GL_PROJECTION); glLoadIdentity();
        glMatrixMode(GL_MODELVIEW); glLoadIdentity();
        glColor4f(1.f, 0.f, 0.f, 1.f);
        glBegin(GL_TRIANGLES);
        glVertex2f(-0.3f, -0.3f); glVertex2f(0.3f, -0.3f); glVertex2f(0.f, 0.3f);
        glEnd();
        if (++frame == 5) {
            unsigned char px[4] = {0, 0, 0, 0};
            glReadPixels(320, 100, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
            printf("OpenGL reads back (%d,%d,%d) at the cleared area\n", px[0], px[1], px[2]);
            fflush(stdout);
        }
        SwapBuffers(dc);
        Sleep(16);
    }
    return 0;
}
