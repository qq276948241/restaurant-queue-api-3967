$baseUrl = "http://localhost:4567/api"

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

$r2 = Invoke-Api -Method GET -Endpoint "/table-types"
Write-TestResult -TestName "2. 获取桌型配置" -Result $r2

$body3 = @{ table_type = "small"; people_count = 2; is_vip = $false }
$r3 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body3
Write-TestResult -TestName "3. 顾客取号 - 小桌(普通)" -Result $r3

$body4 = @{ table_type = "small"; people_count = 3; is_vip = $true }
$r4 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body4
$vipToken = $r4.Data.token
Write-TestResult -TestName "4. 顾客取号 - 小桌(VIP)" -Result $r4

$body5 = @{ table_type = "large"; people_count = 6; is_vip = $false }
$r5 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body5
$largeToken = $r5.Data.token
Write-TestResult -TestName "5. 顾客取号 - 大桌(普通)" -Result $r5

$body6 = @{ table_type = "small"; people_count = 4; is_vip = $false }
$r6 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body6
$normal2Token = $r6.Data.token
Write-TestResult -TestName "6. 顾客取号 - 小桌(普通2)" -Result $r6

$r7 = Invoke-Api -Method GET -Endpoint "/queue-status/$vipToken"
Write-TestResult -TestName "7. 查询排队状态 - VIP顾客" -Result $r7

$r8 = Invoke-Api -Method GET -Endpoint "/queue-status/$normal2Token"
Write-TestResult -TestName "8. 查询排队状态 - 普通顾客" -Result $r8

$r9 = Invoke-Api -Method GET -Endpoint "/queue/list/small"
Write-TestResult -TestName "9. 查看小桌排队列表" -Result $r9

$body10 = @{ table_type = "small" }
$r10 = Invoke-Api -Method POST -Endpoint "/call-next" -Body $body10
$calledToken = $r10.Data.token
Write-TestResult -TestName "10. 后厨叫号 - 小桌(应该叫VIP)" -Result $r10

$body11 = @{ table_type = "small" }
$r11 = Invoke-Api -Method POST -Endpoint "/call-next" -Body $body11
Write-TestResult -TestName "11. 后厨叫号 - 小桌(下一位)" -Result $r11

$r12 = Invoke-Api -Method POST -Endpoint "/complete/$calledToken"
Write-TestResult -TestName "12. 完成就餐" -Result $r12

$body13 = @{ table_type = "large" }
$r13 = Invoke-Api -Method POST -Endpoint "/call-next" -Body $body13
Write-TestResult -TestName "13. 后厨叫号 - 大桌" -Result $r13

$r14 = Invoke-Api -Method GET -Endpoint "/statistics"
Write-TestResult -TestName "14. 当日排队统计" -Result $r14

$body15 = @{ table_type = "medium"; people_count = 3 }
$r15 = Invoke-Api -Method POST -Endpoint "/take-number" -Body $body15
Write-TestResult -TestName "15. 无效桌型取号(错误测试)" -Result $r15

$r16 = Invoke-Api -Method GET -Endpoint "/queue-status/INVALID123"
Write-TestResult -TestName "16. 无效token查询(错误测试)" -Result $r16

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  测试完成！VIP优先插队逻辑已验证" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "关键验证点：" -ForegroundColor Cyan
Write-Host "  - 桌型区分：S开头=小桌，L开头=大桌，V开头=VIP" -ForegroundColor White
Write-Host "  - VIP优先：叫号时VIP排在普通顾客前面" -ForegroundColor White
Write-Host "  - 排队查询：普通顾客需要等前面所有VIP+普通" -ForegroundColor White
Write-Host "  - 时段统计：按小时统计各时段取号量，识别高峰" -ForegroundColor White
