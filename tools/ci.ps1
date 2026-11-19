# This script is only for github action ci
#
# Build and tests run as separate Actions steps so the test output is easy to
# inspect in the UI:
#   - Build step: call this script without -testOnly. It builds and persists
#     the 1kiss build result into GITHUB_ENV for the following step.
#   - Test step:  call this script with -testOnly. It skips the build, reads
#     the persisted build result from the environment and only runs tests.

# Detect our own switch without consuming arguments that must be forwarded to
# build.ps1 (-p, -a, -cc, ... are all passed through in $args).
$testOnly = $args -contains '-testOnly'
if ($testOnly) {
    $args = @($args | Where-Object { $_ -ne '-testOnly' })
}

if (!$testOnly) {
    $build_script = (Resolve-Path $PSScriptRoot/../build.ps1).Path

    # Compose extra cmake options. YASIO_SSL_BACKEND (1=OpenSSL, 2=mbedtls) is set
    # by the CI matrix so every platform can build/test both SSL backends.
    # NOTE: 1kiss.ps1 splits -xc on spaces, so keep options space-separated.
    # CMakeLists.txt also reads YASIO_SSL_BACKEND directly from the environment.
    $cmakeOpts = '-DYASIO_ENABLE_NI=ON'
    if ($env:YASIO_SSL_BACKEND) {
        $cmakeOpts += ' -DYASIO_SSL_BACKEND=' + $env:YASIO_SSL_BACKEND
    }

    . $build_script @args -xc $cmakeOpts -xb '--verbose'

    # 1kiss only sets $env:buildResult on a successful build, and its trailing
    # `exit $LASTEXITCODE` does not terminate the parent pwsh when dot-sourced
    # (the failure log proves the caller keeps running). So we must propagate a
    # build failure ourselves, otherwise the step would wrongly look successful.
    if (-not $env:buildResult) {
        $code = $LASTEXITCODE
        if ($null -eq $code -or $code -eq 0) { $code = 1 }
        Write-Host "Build failed (no buildResult produced); exiting $code"
        exit $code
    }

    # Persist a compact single-line JSON into GITHUB_ENV so the separate Test
    # step (a new pwsh process) can read it.
    if ($env:GITHUB_ENV) {
        try {
            $compact = ($env:buildResult | ConvertFrom-Json | ConvertTo-Json -Compress)
            Add-Content -Path $env:GITHUB_ENV -Value "buildResult=$compact" -Encoding utf8
        }
        catch {
            Write-Host "Failed to persist buildResult: $_"
        }
    }

    # Build step is done; tests run in the dedicated Test step below.
    return
}

# ----------------------------- Test step -----------------------------
$brJson = $env:buildResult
if (!$brJson) {
    Write-Host "No buildResult available; skipping tests (cross-compiled target or failed build)."
    return
}

Write-Host "buildResult: $brJson"
try {
    $buildResult = $brJson | ConvertFrom-Json
}
catch {
    Write-Host "Invalid buildResult JSON; skipping tests."
    return
}

if ($buildResult.isHostTarget) { # run tests
    $targetOS = $buildResult.targetOS
    $buildDir = $buildResult.buildDir
    # run tests
    $testTable = @{
        'win32' = {
            $buildDir = $args[0]
            if ($buildResult.compilerID -ne 'gcc') {
                Write-Host "run icmptest on windows ..."
                & "$buildDir\tests\icmp\Release\icmptest.exe" $env:PING_HOST
                Write-Host "run mtu on windows ..."
                & "$buildDir\tests\mtu\Release\mtutest.exe"
            }
        };
        'linux' = {
            $buildDir = $args[0]
            Write-Host "run issue201 on linux..."
            & "$buildDir/tests/issue201/issue201"

            # Write-Host "run httptest on linux..."
            # & "$buildDir/tests/http/httptest"

            Write-Host "run ssltest on linux..."
            & "$buildDir/tests/ssl/ssltest"
            if ($LASTEXITCODE -ne 0) {
                throw "ssltest failed with exit code $LASTEXITCODE"
            }

            Write-Host "run icmp test on linux..."
            & "$buildDir/tests/icmp/icmptest" $env:PING_HOST

            Write-Host "run mtu on linux ..."
            & "$buildDir/tests/mtu/mtutest"
        };
        'osx' = {
            $buildDir = $args[0]
            if ($buildResult.targetCPU -eq $buildResult.hostCPU) {
                Write-Host "run test tcptest on osx ..."
                & "$buildDir/tests/tcp/Release/tcptest"

                Write-Host "run test issue384 on osx ..."
                & "$buildDir/tests/issue384/Release/issue384"

                Write-Host "run test icmp on osx ..."
                & "$buildDir/tests/icmp/Release/icmptest" $env:PING_HOST

                Write-Host "run mtu on osx ..."
                & "$buildDir/tests/mtu/Release/mtutest"
            }
        };
    }

    # run test
    $run_test = $testTable[$targetOS]
    if ($run_test) {
        & $run_test $buildDir
    }
}
