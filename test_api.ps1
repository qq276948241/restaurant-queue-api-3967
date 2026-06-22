$baseUrl = "http://localhost:4567/api"
$headers = @{"Content-Type"="application/json"}

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Endpoint,
        [hashtable]$Body = $null
    )

    $url = "$baseUrl$Endpoint"
    $params = @{
        Uri = $url
        Method = $Method
        UseBasicParsing = $true
        ContentType = "application/json"
    }

    if ($Body -and $Method -ne "GET") {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-WebRequest @params
        $content = $response.Content | ConvertFrom-Json
        return @{
            Success = $true
            StatusCode = $response.StatusCode
            Data = $content
        }
    } catch {
        $errorContent = $_.Exception.Message
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorContent = $reader.ReadToEnd()
            try {
                $errorContent = $errorContent | ConvertFrom-Json
            } catch {}
        }
        return @{
            Success = $false
            StatusCode = [int]$_.Exception.Response.StatusCode
            Error = $errorContent
        }
    }
}

function Write-TestResult {
    param(
        [string]$TestName,
        [hashtable]$Result
    )

    Write-Host ""
    Write-Host "=== $TestName ===" -ForegroundColor Cyan
    if ($Result.Success) {
        Write-Host "Status: $($Result.StatusCode) OK" -ForegroundColor Green
        Write-Host "Response: $($Result.Data | ConvertTo-Json -Depth 10)" -ForegroundColor Gray
    } else {
        Write-Host "Status: $($Result.StatusCode) FAILED" -ForegroundColor Red
        $err = $Result.Error
        if ($err -is [string]) {
            Write-Host "Error: $err" -ForegroundColor Red
        } else {
            Write-Host "Error: $($err | ConvertTo-Json -Depth 10)" -ForegroundColor Red
        }
    }
}

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  餐厅排队叫号 API 测试" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

$r1 = Invoke-Api -Method GET -Endpoint "/health"
Write-TestResult -TestName "1. 健康检查" -Result $r1

$body2 = @{ table_type = "small"; people_count = 2; is_vip = $false }
$r2 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body2
Write-TestResult -TestName "2. 取小桌普通号1（有预估等待时间）" -Result $r2
if ($r2.Success) {
    $d = $r2.Data
    Write-Host "  预估等待: $($d.estimated_wait_minutes)分钟, 文案: $($d.estimated_wait_text)" -ForegroundColor Magenta
}

$body3 = @{ table_type = "small"; people_count = 3; is_vip = $false }
$r3 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body3
Write-TestResult -TestName "3. 取小桌普通号2（前面1桌，预估15分钟）" -Result $r3
if ($r3.Success) {
    $d = $r3.Data
    Write-Host "  前面桌数: $($d.ahead_count), 预估等待: $($d.estimated_wait_minutes)分钟, 文案: $($d.estimated_wait_text)" -ForegroundColor Magenta
    if ($d.ahead_count -eq 1 -and $d.estimated_wait_minutes -eq 15) {
        Write-Host "  SUCCESS: 预估等待时间正确！" -ForegroundColor Green
    } else {
        Write-Host "  FAILED: 预估等待时间错误，应该是1桌/15分钟" -ForegroundColor Red
    }
}

$body4 = @{ table_type = "small"; people_count = 4; is_vip = $false }
$r4 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body4
$cancelToken = $r4.Data.token
Write-TestResult -TestName "4. 取小桌普通号3（用于取消测试）" -Result $r4
if ($r4.Success) {
    $d = $r4.Data
    Write-Host "  前面桌数: $($d.ahead_count), 预估等待: $($d.estimated_wait_minutes)分钟, 文案: $($d.estimated_wait_text)" -ForegroundColor Magenta
}

$r5 = Invoke-Api -Method GET -Endpoint "/queue-status/$cancelToken"
Write-TestResult -TestName "5. 查询排队状态（含预估等待时间）" -Result $r5
if ($r5.Success) {
    $d = $r5.Data
    Write-Host "  前面桌数: $($d.ahead_count), 预估等待: $($d.estimated_wait_minutes)分钟, 文案: $($d.estimated_wait_text)" -ForegroundColor Magenta
}

$r6 = Invoke-Api -Method POST -Endpoint "/cancel/$cancelToken"
Write-TestResult -TestName "6. 取消排队（成功）" -Result $r6
if ($r6.Success -and $r6.Data.status -eq "cancelled") {
    Write-Host "  SUCCESS: 取消成功！状态为 cancelled" -ForegroundColor Green
} else {
    Write-Host "  FAILED: 取消失败" -ForegroundColor Red
}

$r7 = Invoke-Api -Method POST -Endpoint "/cancel/$cancelToken"
Write-TestResult -TestName "7. 重复取消（应该失败）" -Result $r7
if (-not $r7.Success -and $r7.StatusCode -eq 400) {
    Write-Host "  SUCCESS: 重复取消被正确拒绝！" -ForegroundColor Green
} else {
    Write-Host "  FAILED: 重复取消应该被拒绝" -ForegroundColor Red
}

$invalidToken = "INVALID99"
$r8 = Invoke-Api -Method POST -Endpoint "/cancel/$invalidToken"
Write-TestResult -TestName "8. 取消不存在的token（应该404）" -Result $r8
if (-not $r8.Success -and $r8.StatusCode -eq 404) {
    Write-Host "  SUCCESS: 无效token返回404！" -ForegroundColor Green
} else {
    Write-Host "  FAILED: 无效token应该返回404" -ForegroundColor Red
}

$body9 = @{ table_type = "small" }
$r9 = Invoke-Api -Method POST -Endpoint "/call-next" -Body $body9
$calledToken = $r9.Data.token
Write-TestResult -TestName "9. 叫号（叫到第1位）" -Result $r9

$r10 = Invoke-Api -Method POST -Endpoint "/cancel/$calledToken"
Write-TestResult -TestName "10. 取消已叫号的顾客（应该失败）" -Result $r10
if (-not $r10.Success -and $r10.StatusCode -eq 400) {
    Write-Host "  SUCCESS: 已叫号顾客无法取消！" -ForegroundColor Green
} else {
    Write-Host "  FAILED: 已叫号顾客应该无法取消" -ForegroundColor Red
}

$body11 = @{ table_type = "small"; people_count = 5; is_vip = $true }
$r11 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body11
Write-TestResult -TestName "11. 取VIP号（应该排最前，预估0分钟）" -Result $r11
if ($r11.Success) {
    $d = $r11.Data
    Write-Host "  前面桌数: $($d.ahead_count), 预估等待: $($d.estimated_wait_minutes)分钟, 文案: $($d.estimated_wait_text)" -ForegroundColor Magenta
    if ($d.ahead_count -eq 0 -and $d.estimated_wait_text -eq "即将叫号") {
        Write-Host "  SUCCESS: VIP预估等待即将叫号正确！" -ForegroundColor Green
    }
}

$r12 = Invoke-Api -Method GET -Endpoint "/statistics"
Write-TestResult -TestName "12. 当日统计" -Result $r12

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  测试完成！" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "新增功能验证：" -ForegroundColor Cyan
Write-Host "  - 取消排队接口: POST /api/cancel/:token" -ForegroundColor White
Write-Host "  - 预估等待时间: estimated_wait_minutes + estimated_wait_text" -ForegroundColor White
Write-Host "  - 计算规则: 每桌15分钟，0分钟显示'即将叫号'" -ForegroundColor White
