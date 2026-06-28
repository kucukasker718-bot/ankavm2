import { Dispatch, SetStateAction, useCallback, useEffect, useState } from 'react'
import { Clock, Globe, Lock, LogIn, Monitor, RefreshCw, ShieldCheck, Terminal, Upload, UserCog } from 'lucide-react'
import {
  changePassword,
  changeUsername,
  getLoginLogs,
  getSSLSettings,
  getWebSSHOriginSettings,
  LoginLog,
  SSLSettings,
  updateSSLSettings,
  updateWebSSHOriginSettings,
  WebSSHOriginSettings,
} from '../services/api'
import { useDialog } from '../components/Dialog'
import { useAuth } from '../contexts/AuthContext'

export default function Settings() {
  const dialog = useDialog()
  const { username } = useAuth()
  const [logs, setLogs] = useState<LoginLog[]>([])
  const [loading, setLoading] = useState(true)
  const [logPage, setLogPage] = useState(1)
  const pageSize = 10

  const [oldPwd, setOldPwd] = useState('')
  const [newPwd, setNewPwd] = useState('')
  const [newUsername, setNewUsername] = useState('')

  const [ssl, setSSL] = useState<SSLSettings | null>(null)
  const [sslEnabled, setSSLEnabled] = useState(false)
  const [sslMode, setSSLMode] = useState<SSLSettings['mode']>('disabled')
  const [sslTarget, setSSLTarget] = useState('')
  const [sslEmail, setSSLEmail] = useState('')
  const [certPEM, setCertPEM] = useState('')
  const [keyPEM, setKeyPEM] = useState('')
  const [applyNow, setApplyNow] = useState(true)
  const [savingSSL, setSavingSSL] = useState(false)
  const [webSSHOrigins, setWebSSHOrigins] = useState<WebSSHOriginSettings | null>(null)
  const [webSSHOriginsText, setWebSSHOriginsText] = useState('')
  const [savingWebSSHOrigins, setSavingWebSSHOrigins] = useState(false)

  const fetchLogs = useCallback(async () => {
    try {
      const res = await getLoginLogs()
      if (res.data.data) setLogs(res.data.data)
    } catch (err) {
      console.error(err)
    } finally {
      setLoading(false)
    }
  }, [])

  const fetchSSL = useCallback(async () => {
    try {
      const res = await getSSLSettings()
      const data = res.data.data
      if (!data) return
      setSSL(data)
      setSSLEnabled(data.enabled)
      setSSLMode(data.mode || 'disabled')
      setSSLTarget(data.target || data.detected_host || '')
      setSSLEmail(data.email || '')
    } catch (err) {
      console.error(err)
    }
  }, [])

  const fetchWebSSHOrigins = useCallback(async () => {
    try {
      const res = await getWebSSHOriginSettings()
      const data = res.data.data
      if (!data) return
      setWebSSHOrigins(data)
      setWebSSHOriginsText((data.origins || []).join('\n'))
    } catch (err) {
      console.error(err)
    }
  }, [])

  useEffect(() => {
    fetchLogs()
    fetchSSL()
    fetchWebSSHOrigins()
    const timer = setInterval(fetchLogs, 15000)
    return () => clearInterval(timer)
  }, [fetchLogs, fetchSSL, fetchWebSSHOrigins])

  const handleSSLModeChange = (mode: SSLSettings['mode']) => {
    setSSLMode(mode)
    const saved = ssl?.mode_certificates?.[mode]
    setSSLTarget(saved?.target || ssl?.detected_host || sslTarget)
    setSSLEmail(saved?.email || '')
  }

  const handleSaveSSL = async () => {
    setSavingSSL(true)
    try {
      const enabled = sslEnabled && sslMode !== 'disabled'
      const res = await updateSSLSettings({
        enabled,
        mode: enabled ? sslMode : 'disabled',
        target: sslTarget,
        email: sslEmail,
        cert_pem: certPEM,
        key_pem: keyPEM,
        apply_now: applyNow,
      })
      if (res.data.data) {
        setSSL(res.data.data)
        setCertPEM('')
        setKeyPEM('')
      }
      dialog.alert('完成', applyNow ? 'SSL 设置已保存，服务正在重启。稍后请用新的协议重新打开面板。' : 'SSL 设置已保存，重启 clicd 服务后生效。')
    } catch (err: unknown) {
      const e = err as { response?: { data?: { message?: string } } }
      dialog.alert('失败', e.response?.data?.message || 'SSL 设置保存失败')
    } finally {
      setSavingSSL(false)
    }
  }

  const handleSaveWebSSHOrigins = async () => {
    setSavingWebSSHOrigins(true)
    try {
      const origins = webSSHOriginsText.split(/\r?\n/).map(item => item.trim()).filter(Boolean)
      const res = await updateWebSSHOriginSettings(origins)
      const data = res.data.data
      if (data) {
        setWebSSHOrigins(data)
        setWebSSHOriginsText((data.origins || []).join('\n'))
      }
      dialog.alert('完成', 'Origin 白名单已保存')
    } catch (err: unknown) {
      const e = err as { response?: { data?: { message?: string } } }
      dialog.alert('失败', e.response?.data?.message || 'Origin 白名单保存失败')
    } finally {
      setSavingWebSSHOrigins(false)
    }
  }

  const handleSaveAccount = async () => {
    if (!oldPwd) {
      dialog.alert('提示', '请输入当前密码以确认修改')
      return
    }
    if (!newPwd && !newUsername) {
      dialog.alert('提示', '至少填写新密码或新用户名中的一项')
      return
    }
    if (newPwd && newPwd.length < 6) {
      dialog.alert('提示', '新密码至少 6 位')
      return
    }
    if (newUsername && newUsername.length < 3) {
      dialog.alert('提示', '用户名至少 3 位')
      return
    }

    const results: string[] = []
    try {
      if (newUsername) {
        const res = await changeUsername(newUsername, oldPwd)
        results.push(res.data.success ? '用户名已修改' : '用户名修改失败')
      }
      if (newPwd) {
        const res = await changePassword(oldPwd, newPwd)
        results.push(res.data.success ? '密码已修改' : '密码修改失败')
      }
      if (results.length > 0) {
        dialog.alert('完成', `${results.join('，')}。下次登录生效`)
        setOldPwd('')
        setNewPwd('')
        setNewUsername('')
      }
    } catch (err: unknown) {
      const e = err as { response?: { data?: { message?: string } } }
      dialog.alert('失败', e.response?.data?.message || '修改失败')
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-black"></div>
      </div>
    )
  }

  const totalPages = Math.ceil(logs.length / pageSize)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-black">面板设置</h1>
        <p className="mt-1 text-sm text-gray-500">账号、安全证书与登录日志</p>
      </div>

      <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1.15fr)_minmax(360px,0.85fr)]">
        <div className="space-y-6">
          <SSLCard
            ssl={ssl}
            sslEnabled={sslEnabled}
            sslMode={sslMode}
            sslTarget={sslTarget}
            sslEmail={sslEmail}
            certPEM={certPEM}
            keyPEM={keyPEM}
            applyNow={applyNow}
            savingSSL={savingSSL}
            onRefresh={fetchSSL}
            onEnabledChange={setSSLEnabled}
            onModeChange={handleSSLModeChange}
            onTargetChange={setSSLTarget}
            onEmailChange={setSSLEmail}
            onCertChange={setCertPEM}
            onKeyChange={setKeyPEM}
            onApplyNowChange={setApplyNow}
            onSave={handleSaveSSL}
          />

          <WebSSHOriginCard
            settings={webSSHOrigins}
            originsText={webSSHOriginsText}
            saving={savingWebSSHOrigins}
            onOriginsTextChange={setWebSSHOriginsText}
            onRefresh={fetchWebSSHOrigins}
            onSave={handleSaveWebSSHOrigins}
          />
        </div>

        <div className="rounded-lg border border-gray-200 bg-white p-5">
          <h2 className="mb-4 flex items-center gap-2 text-sm font-semibold text-black">
            <UserCog className="h-4 w-4" />账号设置
          </h2>
          <div className="space-y-4">
            <div>
              <label className="mb-1 block text-xs text-gray-500">当前用户名</label>
              <input type="text" value={username || ''} disabled className="w-full rounded-md border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-400" />
            </div>
            <div>
              <label className="mb-1 block text-xs text-gray-500">新用户名，留空则不修改</label>
              <input type="text" value={newUsername} onChange={(e) => setNewUsername(e.target.value)} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-black" placeholder="至少 3 位" />
            </div>
            <div className="border-t border-gray-100 pt-3">
              <label className="mb-1 block text-xs text-gray-500">新密码，留空则不修改</label>
              <input type="password" value={newPwd} onChange={(e) => setNewPwd(e.target.value)} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-black" placeholder="至少 6 位" />
            </div>
            <div>
              <label className="mb-1 block text-xs text-gray-500">当前密码，验证身份</label>
              <input type="password" value={oldPwd} onChange={(e) => setOldPwd(e.target.value)} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-black" placeholder="输入当前密码以确认修改" />
            </div>
            <button onClick={handleSaveAccount} className="w-full rounded-md bg-black px-4 py-2 text-sm text-white hover:bg-gray-800">保存修改</button>
          </div>
        </div>
      </div>

      <LoginLogCard logs={logs} logPage={logPage} pageSize={pageSize} totalPages={totalPages} setLogPage={setLogPage} />
    </div>
  )
}

interface SSLCardProps {
  ssl: SSLSettings | null
  sslEnabled: boolean
  sslMode: SSLSettings['mode']
  sslTarget: string
  sslEmail: string
  certPEM: string
  keyPEM: string
  applyNow: boolean
  savingSSL: boolean
  onRefresh: () => void
  onEnabledChange: (enabled: boolean) => void
  onModeChange: (mode: SSLSettings['mode']) => void
  onTargetChange: (target: string) => void
  onEmailChange: (email: string) => void
  onCertChange: (cert: string) => void
  onKeyChange: (key: string) => void
  onApplyNowChange: (apply: boolean) => void
  onSave: () => void
}

interface WebSSHOriginCardProps {
  settings: WebSSHOriginSettings | null
  originsText: string
  saving: boolean
  onOriginsTextChange: (value: string) => void
  onRefresh: () => void
  onSave: () => void
}

function WebSSHOriginCard(props: WebSSHOriginCardProps) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-5">
      <div className="mb-4 flex items-center justify-between gap-3">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-black">
          <Terminal className="h-4 w-4" />WebSSH Origin 白名单
        </h2>
        <button onClick={props.onRefresh} className="rounded-md border border-gray-200 p-1.5 text-gray-500 hover:bg-gray-50" title="刷新">
          <RefreshCw className="h-4 w-4" />
        </button>
      </div>
      <div className="space-y-3">
        <div>
          <label className="mb-1 block text-xs text-gray-500">允许的 Origin</label>
          <textarea
            value={props.originsText}
            onChange={(e) => props.onOriginsTextChange(e.target.value)}
            rows={5}
            className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 font-mono text-xs text-black"
          />
        </div>
        <div className="rounded-md border border-gray-100 bg-gray-50 p-3 text-xs text-gray-600">
          <div className="truncate font-mono" title={props.settings?.current_origin || ''}>当前面板来源：{props.settings?.current_origin || '-'}</div>
          <div className="mt-1">默认允许当前面板来源和本机回环来源；额外域名每行填写一个完整 Origin。</div>
        </div>
        <button onClick={props.onSave} disabled={props.saving} className="inline-flex w-full items-center justify-center gap-2 rounded-md bg-black px-4 py-2 text-sm text-white hover:bg-gray-800 disabled:opacity-50">
          <Upload className="h-4 w-4" />
          {props.saving ? '保存中...' : '保存 Origin 白名单'}
        </button>
      </div>
    </div>
  )
}

function SSLCard(props: SSLCardProps) {
  const selectedSSL = props.ssl?.mode_certificates?.[props.sslMode]
  const modeOptions: Array<{ value: SSLSettings['mode']; label: string }> = [
    { value: 'letsencrypt', label: 'Let’s Encrypt' },
    { value: 'self_signed', label: '自签证书' },
    { value: 'uploaded', label: '上传证书' },
  ]

  return (
    <div className="rounded-lg border border-gray-200 bg-white p-5">
      <div className="mb-4 flex items-center justify-between gap-3">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-black">
          <ShieldCheck className="h-4 w-4" />SSL 证书
        </h2>
        <button onClick={props.onRefresh} className="rounded-md border border-gray-200 p-1.5 text-gray-500 hover:bg-gray-50" title="刷新">
          <RefreshCw className="h-4 w-4" />
        </button>
      </div>
      <div className="space-y-4">
        <label className="flex items-center gap-2 text-sm text-gray-700">
          <input type="checkbox" checked={props.sslEnabled} onChange={(e) => props.onEnabledChange(e.target.checked)} className="h-4 w-4 rounded border-gray-300" />
          启用 HTTPS / WSS
        </label>

        <div className="grid gap-2 sm:grid-cols-3">
          {modeOptions.map((option) => (
            <button
              key={option.value}
              onClick={() => props.onModeChange(option.value)}
              className={`rounded-md border px-3 py-2 text-sm ${props.sslMode === option.value ? 'border-black bg-black text-white' : 'border-gray-200 text-gray-700 hover:bg-gray-50'}`}
            >
              {option.label}
            </button>
          ))}
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <div>
            <label className="mb-1 block text-xs text-gray-500">IP / 域名</label>
            <input
              type="text"
              value={props.sslTarget}
              onChange={(e) => props.onTargetChange(e.target.value)}
              className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-black"
              placeholder={props.ssl?.detected_host || '服务器公网 IP 或域名'}
            />
          </div>
          {props.sslMode === 'letsencrypt' && (
            <div>
              <label className="mb-1 block text-xs text-gray-500">邮箱，可选</label>
              <input type="email" value={props.sslEmail} onChange={(e) => props.onEmailChange(e.target.value)} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-black" placeholder="admin@example.com" />
            </div>
          )}
        </div>

        {props.sslMode === 'letsencrypt' && (
          <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-xs text-amber-800">
            纯 IP 证书需要服务器安装 Certbot 5.4+，且验证时 80 端口必须能被 Let’s Encrypt 访问。IP 证书是短有效期证书，certbot 需要保持自动续签。
          </div>
        )}

        {props.sslMode === 'self_signed' && (
          <div className="rounded-md border border-gray-100 bg-gray-50 p-3 text-xs text-gray-600">
            自签证书可以加密面板和 VNC，但浏览器会提示证书不受信任；证书快到期时系统会自动重新签发。
          </div>
        )}

        {props.sslMode === 'uploaded' && (
          <div className="grid gap-3 lg:grid-cols-2">
            <div>
              <label className="mb-1 block text-xs text-gray-500">证书 PEM / fullchain.pem</label>
              <textarea value={props.certPEM} onChange={(e) => props.onCertChange(e.target.value)} rows={7} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 font-mono text-xs text-black" placeholder="-----BEGIN CERTIFICATE-----" />
            </div>
            <div>
              <label className="mb-1 block text-xs text-gray-500">私钥 PEM / privkey.pem</label>
              <textarea value={props.keyPEM} onChange={(e) => props.onKeyChange(e.target.value)} rows={7} className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 font-mono text-xs text-black" placeholder="-----BEGIN PRIVATE KEY-----" />
            </div>
          </div>
        )}

        {selectedSSL?.certificate ? (
          <div className="rounded-md border border-gray-100 bg-gray-50 p-3 text-xs text-gray-600">
            <div className="flex items-center gap-2 text-gray-800">
              <Lock className="h-3.5 w-3.5" />
              当前证书：{selectedSSL.certificate.valid ? '有效' : '已过期或未生效'}
            </div>
            <div className="mt-1 font-mono">到期时间：{selectedSSL.certificate.not_after}</div>
            <div className="mt-1 truncate font-mono" title={selectedSSL.cert_path}>证书路径：{selectedSSL.cert_path || '-'}</div>
            {selectedSSL.last_error && <div className="mt-1 text-red-600">最近错误：{selectedSSL.last_error}</div>}
          </div>
        ) : (
          <div className="rounded-md border border-gray-100 bg-gray-50 p-3 text-xs text-gray-600">
            {props.sslMode === 'uploaded' ? '上传来源还没有保存证书，请粘贴证书和私钥后保存。' : '当前来源还没有保存证书，保存 SSL 设置时会自动生成或申请。'}
          </div>
        )}

        <label className="flex items-center gap-2 text-xs text-gray-500">
          <input type="checkbox" checked={props.applyNow} onChange={(e) => props.onApplyNowChange(e.target.checked)} className="h-4 w-4 rounded border-gray-300" />
          保存后自动重启服务并立即生效
        </label>

        <button onClick={props.onSave} disabled={props.savingSSL} className="inline-flex w-full items-center justify-center gap-2 rounded-md bg-black px-4 py-2 text-sm text-white hover:bg-gray-800 disabled:opacity-50">
          <Upload className="h-4 w-4" />
          {props.savingSSL ? '保存中...' : '保存 SSL 设置'}
        </button>
      </div>
    </div>
  )
}

interface LoginLogCardProps {
  logs: LoginLog[]
  logPage: number
  pageSize: number
  totalPages: number
  setLogPage: Dispatch<SetStateAction<number>>
}

function LoginLogCard({ logs, logPage, pageSize, totalPages, setLogPage }: LoginLogCardProps) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-5">
      <h2 className="mb-4 flex items-center gap-2 text-sm font-semibold text-black">
        <LogIn className="h-4 w-4" />登录日志
      </h2>
      {logs.length === 0 ? (
        <p className="text-sm text-gray-400">暂无登录记录</p>
      ) : (
        <>
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b border-gray-100 text-gray-400">
                  <th className="w-40 py-2 text-left font-medium"><span className="inline-flex items-center gap-1"><Clock className="h-3 w-3" />时间</span></th>
                  <th className="py-2 text-left font-medium">用户名</th>
                  <th className="py-2 text-left font-medium"><span className="inline-flex items-center gap-1"><Globe className="h-3 w-3" />IP</span></th>
                  <th className="py-2 text-left font-medium"><span className="inline-flex items-center gap-1"><Monitor className="h-3 w-3" />设备</span></th>
                  <th className="py-2 text-left font-medium">结果</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-50">
                {logs.slice((logPage - 1) * pageSize, logPage * pageSize).map((log, index) => (
                  <tr key={`${log.time}-${index}`}>
                    <td className="whitespace-nowrap py-1.5 font-mono text-gray-500">{log.time}</td>
                    <td className="py-1.5 text-gray-700">{log.username}</td>
                    <td className="py-1.5 font-mono text-gray-500">{log.ip}</td>
                    <td className="max-w-[180px] truncate py-1.5 text-gray-500" title={log.user_agent}>{formatUA(log.user_agent)}</td>
                    <td className="py-1.5">
                      <span className={`rounded px-1.5 py-0.5 text-xs ${log.success ? 'bg-gray-100 text-gray-700' : 'bg-red-50 text-red-600'}`}>
                        {log.success ? '成功' : '失败'}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {logs.length > pageSize && (
            <div className="mt-3 flex items-center justify-between border-t border-gray-100 pt-3">
              <span className="text-xs text-gray-400">共 {logs.length} 条，第 {logPage}/{totalPages} 页</span>
              <div className="flex items-center gap-1">
                <button onClick={() => setLogPage(1)} disabled={logPage === 1} className="rounded border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50 disabled:opacity-30">首页</button>
                <button onClick={() => setLogPage(p => Math.max(1, p - 1))} disabled={logPage === 1} className="rounded border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50 disabled:opacity-30">上一页</button>
                <button onClick={() => setLogPage(p => Math.min(totalPages, p + 1))} disabled={logPage >= totalPages} className="rounded border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50 disabled:opacity-30">下一页</button>
                <button onClick={() => setLogPage(totalPages)} disabled={logPage >= totalPages} className="rounded border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50 disabled:opacity-30">末页</button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function formatUA(ua: string): string {
  const parts: string[] = []
  if (ua.includes('Windows NT')) parts.push('Windows')
  else if (ua.includes('Mac OS X')) parts.push('macOS')
  else if (ua.includes('Linux')) parts.push('Linux')
  else if (ua.includes('Android')) parts.push('Android')
  else if (ua.includes('iPhone') || ua.includes('iPad')) parts.push('iOS')

  if (ua.includes('Chrome') && !ua.includes('Edg')) parts.push('Chrome')
  else if (ua.includes('Firefox')) parts.push('Firefox')
  else if (ua.includes('Edg')) parts.push('Edge')
  else if (ua.includes('Safari') && !ua.includes('Chrome')) parts.push('Safari')

  return parts.join(' / ') || ua.substring(0, 40)
}
