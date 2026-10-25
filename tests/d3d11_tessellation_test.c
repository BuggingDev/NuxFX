// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NuxFX contributors
// Draws one tessellated quad (vertex, hull, domain and pixel shader, compiled with D3DCompile) into a
// 64x64 render target through DXVK and counts the red pixels. The quad covers about 2700 pixels for
// every tessellation factor, so the count shows whether the hull and domain stages run and whether the
// factor reaches the driver: DXVK clamps the factor to the device's maxTessellationGenerationLevel.
// Build and run with tests/run_d3d11_tessellation_test.sh.
//
// Usage: tess.exe <factor>
// Exit codes: 0 pass, 1 setup failed, 12 nothing was drawn, 13 the covered area is wrong.
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *hlsl =
    "struct VSOut { float2 pos : POSITION; };\n"
    "VSOut vs_main(uint id : SV_VertexID) {\n"
    "    float2 p[4] = { float2(-0.8, -0.8), float2(0.8, -0.8), float2(-0.8, 0.8), float2(0.8, 0.8) };\n"
    "    VSOut o; o.pos = p[id]; return o;\n"
    "}\n"
    "struct HSConst { float edges[4] : SV_TessFactor; float inside[2] : SV_InsideTessFactor; };\n"
    "HSConst hs_const(InputPatch<VSOut, 4> patch) {\n"
    "    HSConst c;\n"
    "    c.edges[0] = c.edges[1] = c.edges[2] = c.edges[3] = FACTOR;\n"
    "    c.inside[0] = c.inside[1] = FACTOR;\n"
    "    return c;\n"
    "}\n"
    "[domain(\"quad\")] [partitioning(\"integer\")] [outputtopology(\"triangle_cw\")]\n"
    "[outputcontrolpoints(4)] [patchconstantfunc(\"hs_const\")]\n"
    "VSOut hs_main(InputPatch<VSOut, 4> patch, uint i : SV_OutputControlPointID) { return patch[i]; }\n"
    "struct DSOut { float4 pos : SV_Position; };\n"
    "[domain(\"quad\")]\n"
    "DSOut ds_main(HSConst c, float2 uv : SV_DomainLocation, const OutputPatch<VSOut, 4> patch) {\n"
    "    float2 a = lerp(patch[0].pos, patch[1].pos, uv.x);\n"
    "    float2 b = lerp(patch[2].pos, patch[3].pos, uv.x);\n"
    "    DSOut o; o.pos = float4(lerp(a, b, uv.y), 0, 1); return o;\n"
    "}\n"
    "float4 ps_main() : SV_Target { return float4(1, 0, 0, 1); }\n";

typedef HRESULT (WINAPI *PFN_D3DCompile_)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *,
                                          LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

static PFN_D3DCompile_ compile_fn;
static const D3D_SHADER_MACRO *macros;

static ID3DBlob *compile(const char *entry, const char *target) {
    ID3DBlob *code = NULL, *err = NULL;
    HRESULT hr = compile_fn(hlsl, strlen(hlsl), "tess.hlsl", macros, NULL, entry, target, 0, 0, &code, &err);
    if (FAILED(hr)) {
        printf("D3DCompile %s (%s) failed hr=0x%08lx: %s\n", entry, target, (unsigned long)hr,
               err ? (const char *)err->lpVtbl->GetBufferPointer(err) : "");
        return NULL;
    }
    return code;
}

int main(int argc, char **argv) {
    const char *factor = argc > 1 ? argv[1] : "8";
    D3D_SHADER_MACRO defs[2] = {{"FACTOR", factor}, {NULL, NULL}};
    macros = defs;
    HMODULE comp = LoadLibraryA("d3dcompiler_47.dll");
    compile_fn = comp ? (PFN_D3DCompile_)GetProcAddress(comp, "D3DCompile") : NULL;
    if (!compile_fn) {
        printf("d3dcompiler_47.dll has no D3DCompile\n");
        return 1;
    }

    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0, got = 0;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1, D3D11_SDK_VERSION, &dev,
                                   &got, &ctx);
    printf("device hr=0x%08lx feature level 0x%x, tessellation factor %s\n", (unsigned long)hr, (unsigned)got, factor);
    fflush(stdout);
    if (FAILED(hr))
        return 1;

    ID3DBlob *vsb = compile("vs_main", "vs_5_0"), *hsb = compile("hs_main", "hs_5_0");
    ID3DBlob *dsb = compile("ds_main", "ds_5_0"), *psb = compile("ps_main", "ps_5_0");
    if (!vsb || !hsb || !dsb || !psb)
        return 1;
    ID3D11VertexShader *vs = NULL;
    ID3D11HullShader *hs = NULL;
    ID3D11DomainShader *ds = NULL;
    ID3D11PixelShader *ps = NULL;
    hr = dev->lpVtbl->CreateVertexShader(dev, vsb->lpVtbl->GetBufferPointer(vsb), vsb->lpVtbl->GetBufferSize(vsb), NULL, &vs);
    if (SUCCEEDED(hr))
        hr = dev->lpVtbl->CreateHullShader(dev, hsb->lpVtbl->GetBufferPointer(hsb), hsb->lpVtbl->GetBufferSize(hsb), NULL, &hs);
    if (SUCCEEDED(hr))
        hr = dev->lpVtbl->CreateDomainShader(dev, dsb->lpVtbl->GetBufferPointer(dsb), dsb->lpVtbl->GetBufferSize(dsb), NULL, &ds);
    if (SUCCEEDED(hr))
        hr = dev->lpVtbl->CreatePixelShader(dev, psb->lpVtbl->GetBufferPointer(psb), psb->lpVtbl->GetBufferSize(psb), NULL, &ps);
    printf("create shaders hr=0x%08lx\n", (unsigned long)hr);
    fflush(stdout);
    if (FAILED(hr))
        return 1;

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = 64;
    td.Height = 64;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *rt = NULL, *staging = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    if (FAILED(dev->lpVtbl->CreateTexture2D(dev, &td, NULL, &rt)) ||
        FAILED(dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv)))
        return 1;
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(dev->lpVtbl->CreateTexture2D(dev, &td, NULL, &staging)))
        return 1;

    D3D11_RASTERIZER_DESC rd;
    memset(&rd, 0, sizeof(rd));
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    ID3D11RasterizerState *rs = NULL;
    if (FAILED(dev->lpVtbl->CreateRasterizerState(dev, &rd, &rs)))
        return 1;

    const float black[4] = {0, 0, 0, 1};
    D3D11_VIEWPORT vp = {0, 0, 64, 64, 0, 1};
    ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, black);
    ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ctx->lpVtbl->RSSetViewports(ctx, 1, &vp);
    ctx->lpVtbl->RSSetState(ctx, rs);
    ctx->lpVtbl->IASetInputLayout(ctx, NULL);
    ctx->lpVtbl->IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_4_CONTROL_POINT_PATCHLIST);
    ctx->lpVtbl->VSSetShader(ctx, vs, NULL, 0);
    ctx->lpVtbl->HSSetShader(ctx, hs, NULL, 0);
    ctx->lpVtbl->DSSetShader(ctx, ds, NULL, 0);
    ctx->lpVtbl->PSSetShader(ctx, ps, NULL, 0);
    ctx->lpVtbl->Draw(ctx, 4, 0);
    ctx->lpVtbl->CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)rt);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->lpVtbl->Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m)))
        return 1;
    int red = 0;
    for (int y = 0; y < 64; y++) {
        const unsigned char *row = (const unsigned char *)m.pData + y * m.RowPitch;
        for (int x = 0; x < 64; x++)
            if (row[x * 4] > 200 && row[x * 4 + 1] < 40 && row[x * 4 + 2] < 40)
                red++;
    }
    printf("red pixels %d (expected about 2700)\n", red);
    fflush(stdout);

    /* End like a D3D11 program should: release everything, so that DXVK stops its pipeline compiler
     * threads before the process exits (a process that exits while they still compile can die at exit
     * on this stack, in a few starts out of a hundred). */
    ctx->lpVtbl->Unmap(ctx, (ID3D11Resource *)staging, 0);
    ctx->lpVtbl->ClearState(ctx);
    ctx->lpVtbl->Flush(ctx);
    rs->lpVtbl->Release(rs);
    staging->lpVtbl->Release(staging);
    rtv->lpVtbl->Release(rtv);
    rt->lpVtbl->Release(rt);
    ps->lpVtbl->Release(ps);
    ds->lpVtbl->Release(ds);
    hs->lpVtbl->Release(hs);
    vs->lpVtbl->Release(vs);
    ctx->lpVtbl->Release(ctx);
    dev->lpVtbl->Release(dev);

    if (red == 0)
        return 12;
    return (red < 2400 || red > 3000) ? 13 : 0;
}
