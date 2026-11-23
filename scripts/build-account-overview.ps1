param(
    [string]$OutputPath,
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$projectRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
} else {
    [IO.Path]::GetFullPath($ProjectRoot)
}
$accountsPath = Join-Path $projectRoot 'config\accounts.json'
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot 'PORTFOLIO.md'
}

$accounts = Get-Content -LiteralPath $accountsPath -Raw | ConvertFrom-Json
$lines = [Collections.Generic.List[string]]::new()

function Get-ArrayProperty {
    param([object]$Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) {
        $property.Value
    }
}

function Format-ObservedAt {
    param([object]$Value)
    if ($null -eq $Value) { return '未知' }
    ([DateTimeOffset]$Value).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Format-PlainNumber {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    try { return ([decimal]$Value).ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture) }
    catch { return [string]$Value }
}
$lines.Add('# 账户总览（自动生成）')
$lines.Add('')
$lines.Add('> 这是给 Agent 的快速入口；权威数据仍是 `state/current/*.json`。修改账户 JSON 后运行 `scripts/build-account-overview.ps1`。')
$lines.Add('> `verificationRequired: true` 表示这只是最后确认状态，分析前仍须用新截图或导出核验。')
$lines.Add('')
foreach ($account in $accounts.accounts) {
    $statePath = Join-Path $projectRoot $account.stateFile
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $lines.Add("## $($account.label) ($($account.id))")
    $lines.Add('')
    $lines.Add("- 所有权：$($account.ownership)")
    $lines.Add("- 最后观察时间：$(Format-ObservedAt $state.observedAt)")
    $lines.Add("- 最后确认动作时间：$(Format-ObservedAt $state.lastEventAt)")
    $lines.Add("- 来源：$($state.source ?? '未知')")
    $lines.Add("- 需要重新核验：$([bool]$state.verificationRequired)")
    if ($null -ne $state.reportedTotalAssetValueUsd) {
        $lines.Add("- 最近报告总资产：$($state.reportedTotalAssetValueUsd) USD")
    } elseif ($null -ne $state.reportedTotalAssetValueCny) {
        $lines.Add("- 最近报告总资产：$($state.reportedTotalAssetValueCny) CNY")
    } elseif ($null -ne $state.reportedAssetValueUsd) {
        $lines.Add("- 最近报告资产值：$($state.reportedAssetValueUsd) USD")
    }
    if ($null -ne $state.reportedRobotAssetValueUsd) {
        $lines.Add("- 最近报告机器人资产：$($state.reportedRobotAssetValueUsd) USD")
    }
    $lines.Add('')

    $balances = @(Get-ArrayProperty -Object $state -Name 'balances')
    if ($balances.Count -gt 0) {
        $lines.Add('### 余额')
        $lines.Add('')
        $lines.Add('| 资产 | 数量 | 报告价值 USD |')
        $lines.Add('|---|---:|---:|')
        foreach ($item in $balances) {
            $lines.Add("| $($item.asset) | $($item.quantity) | $($item.reportedValueUsd) |")
        }
        $lines.Add('')
    }

    $reservedFunds = @(Get-ArrayProperty -Object $state -Name 'reservedFunds')
    if ($reservedFunds.Count -gt 0) {
        $lines.Add('### 专用预留资金')
        $lines.Add('')
        $lines.Add('| 账户桶 | 资产 | 数量 | 报告价值 USD | 用途 | 普通限价单可用 |')
        $lines.Add('|---|---|---:|---:|---|---|')
        foreach ($item in $reservedFunds) {
            $purpose = @($item.purpose) -join '、'
            $lines.Add("| $($item.accountBucket) | $($item.asset) | $($item.quantity) | $($item.reportedValueUsd) | $purpose | $($item.availableForOrdinaryLimitOrders) |")
        }
        $lines.Add('')
    }

    $positions = @(Get-ArrayProperty -Object $state -Name 'positions')
    $lines.Add("### 持仓（$($positions.Count)）")
    $lines.Add('')
    if ($positions.Count -eq 0) {
        $lines.Add('当前文件未记录可确认持仓。')
    } else {
        $lines.Add('| 标的 | 数量 | 成本/报告价值 |')
        $lines.Add('|---|---:|---:|')
        foreach ($item in $positions) {
            $metric = if ($null -ne $item.averageCost) { "成本 $($item.averageCost) $($item.currency)" } elseif ($null -ne $item.reportedValueUsd) { "$($item.reportedValueUsd) USD" } else { '未记录' }
            $name = if ($item.name) { "$($item.symbol)（$($item.name)）" } else { [string]$item.symbol }
            $lines.Add("| $name | $($item.quantity) | $metric |")
        }
    }
    $lines.Add('')

    $orders = @(Get-ArrayProperty -Object $state -Name 'orders')
    $lines.Add("### 委托（$($orders.Count)）")
    $lines.Add('')
    if ($orders.Count -eq 0) {
        $lines.Add('当前文件未记录未完成委托。')
    } else {
        foreach ($item in $orders) {
            $price = if ($null -ne $item.price) { "，价格 $(Format-PlainNumber $item.price) $($item.quote)" } else { '' }
            $quantity = if ($null -ne $item.quantity) { "，数量 $($item.quantity)" } else { '' }
            $stage = if ($item.stage) { "，阶段 $($item.stage)" } else { '' }
            $lines.Add("- $($item.symbol)：$($item.side)$price$quantity$stage，状态 $($item.status)")
        }
    }
    $lines.Add('')

    $proposedOrders = @(Get-ArrayProperty -Object $state -Name 'proposedOrders')
    $lines.Add("### 已建议、未确认执行（$($proposedOrders.Count)）")
    $lines.Add('')
    if ($proposedOrders.Count -eq 0) {
        $lines.Add('当前文件未记录尚未确认执行的具体订单建议。')
    } else {
        foreach ($item in $proposedOrders) {
            $price = if ($null -ne $item.price) { "，建议价 $(Format-PlainNumber $item.price) $($item.quote)" } else { '' }
            $amount = if ($null -ne $item.quoteAmount) { "，建议金额 $($item.quoteAmount) $($item.quote)" } elseif ($null -ne $item.quantity) { "，数量 $($item.quantity)" } else { '' }
            $lines.Add("- $($item.symbol)：$($item.side)$price$amount，状态 proposed（不计入真实挂单）")
        }
    }
    $lines.Add('')

    $deferredOrders = @(Get-ArrayProperty -Object $state -Name 'deferredOrders')
    $lines.Add("### 延后挂单（$($deferredOrders.Count)）")
    $lines.Add('')
    if ($deferredOrders.Count -eq 0) {
        $lines.Add('当前文件未记录等待条件的挂单计划。')
    } else {
        foreach ($item in $deferredOrders) {
            $price = if ($null -ne $item.price) { "，目标价 $(Format-PlainNumber $item.price) $($item.quote)" } else { '' }
            $amount = if ($null -ne $item.quoteAmount) { "，计划金额 $($item.quoteAmount) $($item.quote)" } elseif ($null -ne $item.quantity) { "，数量 $($item.quantity)" } else { '' }
            $condition = if ($item.reminderCondition) { "，提醒条件 $($item.reminderCondition)" } else { '' }
            $lines.Add("- $($item.symbol)：$($item.side)$price$amount$condition，状态 deferred")
        }
    }
    $lines.Add('')

    $bots = @(Get-ArrayProperty -Object $state -Name 'bots')
    $lines.Add("### 机器人（$($bots.Count)）")
    $lines.Add('')
    if ($bots.Count -eq 0) {
        $lines.Add('当前文件未记录运行中机器人。')
    } else {
        $lines.Add('| 市场 | 标的 | 策略 | 投入/保证金 | 区间 | 网格数 |')
        $lines.Add('|---|---|---|---:|---|---:|')
        foreach ($item in $bots) {
            $capital = if ($null -ne $item.investment) { $item.investment } else { $item.margin }
            $range = if ($item.range) { "$($item.range[0])–$($item.range[1])" } else { '未记录' }
            $lines.Add("| $($item.market) | $($item.symbol) | $($item.strategy) | $capital $($item.quote) | $range | $($item.gridCount) |")
        }
    }
    $lines.Add('')

    $stoppedBots = @(Get-ArrayProperty -Object $state -Name 'stoppedBots')
    $lines.Add("### 已停止机器人（$($stoppedBots.Count)）")
    $lines.Add('')
    if ($stoppedBots.Count -eq 0) {
        $lines.Add('当前文件未记录已停止机器人。')
    } else {
        foreach ($item in $stoppedBots) {
            $capital = if ($null -ne $item.investment) { $item.investment } else { $item.margin }
            $result = if ($null -ne $item.totalPnl) { $item.totalPnl } elseif ($null -ne $item.reportedTotalPnlUsd) { $item.reportedTotalPnlUsd } else { '未记录' }
            $lines.Add("- $($item.symbol)：停止时间 $(Format-ObservedAt $item.stoppedAt)，投入/保证金 $capital $($item.quote)，最终盈亏 $result")
        }
    }
    $lines.Add('')

    $pending = @(Get-ArrayProperty -Object $state -Name 'pendingVerifications')
    if ($pending.Count -gt 0) {
        $lines.Add("### 待核验动作（$($pending.Count)）")
        $lines.Add('')
        foreach ($item in $pending) {
            $lines.Add("- $($item.eventId)：$($item.eventType)，原因 $($item.reason)，发生时间 $($item.occurredAt)")
        }
        $lines.Add('')
    }

    $failed = @(Get-ArrayProperty -Object $state -Name 'failedEvents')
    if ($failed.Count -gt 0) {
        $lines.Add("### 失败动作（$($failed.Count)）")
        $lines.Add('')
        foreach ($item in $failed) {
            $lines.Add("- $($item.eventId)：$($item.eventType)，原因 $($item.reason)，发生时间 $($item.occurredAt)")
        }
        $lines.Add('')
    }

    $transfers = @(Get-ArrayProperty -Object $state -Name 'transfers')
    if ($transfers.Count -gt 0) {
        $lines.Add("### 转账结果（$($transfers.Count)）")
        $lines.Add('')
        foreach ($item in $transfers) {
            $transferId = if ($item.transferId) { $item.transferId } else { $item.eventId }
            $lines.Add("- $transferId：$($item.status)，发生时间 $(Format-ObservedAt $item.updatedAt)")
        }
        $lines.Add('')
    }

    if (@($state.notes).Count -gt 0) {
        $lines.Add('### 说明')
        $lines.Add('')
        $lines.Add('> 以下为原始截图或历史口径备注；当前余额、持仓、委托、预留资金和机器人状态以上方投影及 `state/current/` 为准。')
        $lines.Add('')
        foreach ($note in $state.notes) {
            $lines.Add("- $note")
        }
        $lines.Add('')
    }
}

$content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
$target = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $target -Force
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
Write-Output $target
