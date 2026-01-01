@echo off
setlocal

echo Precompiling shaders...
@REM cso files contain dxil bytecode for DirectX 12

dxc -T vs_6_0 -E main -Fo shaders/dxil/Triangle.vs.dxil -Zi -Qembed_debug shaders/Triangle.vs.hlsl
if %errorlevel% neq 0 (
    echo Vertex shader compilation failed!
    exit /b %errorlevel%
)

dxc -T ps_6_0 -E main -Fo shaders/dxil/Triangle.fs.dxil -Zi -Qembed_debug shaders/Triangle.fs.hlsl
if %errorlevel% neq 0 (
    echo Pixel shader compilation failed!
    exit /b %errorlevel%
)

echo Building Odin project...

odin build . -o:speed -subsystem:windows
if %errorlevel% neq 0 (
    echo Build failed!
    exit /b %errorlevel%
)

echo Build created successfully.
endlocal
