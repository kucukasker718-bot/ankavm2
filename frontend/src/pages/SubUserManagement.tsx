import { useCallback, useEffect, useState } from 'react'
import { Copy, KeyRound, LogIn, RefreshCw, ScrollText, UserCog, X } from 'lucide-react'
import { useDialog } from '../components/Dialog'
import api, { AuditLog, LoginLog } from '../services/api'
import { copyToClipboard } from '../utils/clipboard'

interface SubUserItem {
  id: string
  username: string
  container_names: string[]
  container_uuids: string[]
  container_name: string
  container_uuid: string
  access_code: string
  password?: string
  created_at: string
  last_login: string
  last_login_ip: string
  last_login_ua: string
}

interface AuditLogExt extends AuditLog {
  ip?: string
  user_agent?: string
  success?: boolean
  error?: string
}

export default function SubUserManagement() {
  const dialog = useDialog()
  const [users, setUsers] = useState<SubUserItem[]>([])
  const [loading, setLoading] = useState(true)
  const [auditLogs, setAuditLogs] = useState<AuditLogExt[] | null>(null)
  const [loginLogs, setLoginLogs] = useState<LoginLog[] | null>(null)
  const [modalTitle, setModalTitle] = useState('')
  const [passwordUser, setPasswordUser] = useState<SubUserItem | null>(null)
  const [rotatingPassword, setRotatingPassword] = useState(false)
  const [logPage, setLogPage] = useState(1)
  const [logPageSize, setLogPageSize] = useState(10)

  const fetchUsers = useCallback(async () => {
    try {
      const res = await api.get<{ success: boolean; data: SubUserItem[] }>('/sub-users')
      setUsers(res.data.data || [])
    } catch (err) {
      console.error(err)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { fetchUsers() }, [fetchUsers])

  const managementUrl = (user: SubUserItem) => `${window.location.origin}/login?code=${user.access_code}`

  const copyText = async (text: string) => {
    await copyToClipboard(text)
  }

  const rotatePassword = async (user: SubUserItem) => {
    setRotatingPassword(true)
    try {
      const res = await api.post(`/sub-users/${user.id}/rotate-password`)
      const data = res.data.data
      const updatedUser = {
        ...user,
        username: data?.username || user.username,
        access_code: data?.access_code || user.access_code,
        password: data?.password || '',
      }
      setUsers((prev) => prev.map((item) => (item.id === user.id ? updatedUser : item)))
      setPasswordUser(updatedUser)
    } catch (err: unknown) {
      const error = err as { response?: { data?: { message?: string } } }
      dialog.alert('轮换失败', error.response?.data?.message || '请稍后重试')
    } finally {
      setRotatingPassword(false)
    }
  }

  const showAuditLogs = async (user: SubUserItem) => {
    try {
      const res = await api.get(`/sub-users/${user.id}/audit-logs`)
      setAuditLogs(res.data.data || [])
      setLoginLogs(null)
      setModalTitle(`${user.username} - 操作日志`)
      setLogPage(1)
    } catch {
      dialog.alert('错误', '获取操作日志失败')
    }
  }

  const showLoginLogs = async (user: SubUserItem) => {
    try {
      const res = await api.get(`/sub-users/${user.id}/login-logs`)
      setLoginLogs(res.data.data || [])
      setAuditLogs(null)
      setModalTitle(`${user.username} - 登录日志`)
      setLogPage(1)
    } catch {
      dialog.alert('错误', '获取登录日志失败')
    }
  }

  const closeModal = () => {
    setAuditLogs(null)
    setLoginLogs(null)
  }

  const currentLogTotal = auditLogs?.length ?? loginLogs?.length ?? 0
  const logTotalPages = Math.max(1, Math.ceil(currentLogTotal / logPageSize))
  const currentLogPage = Math.min(logPage, logTotalPages)
  const logStart = (currentLogPage - 1) * logPageSize
  const currentAuditLogs = auditLogs?.slice(logStart, logStart + logPageSize)
  const currentLoginLogs = loginLogs?.slice(logStart, logStart + logPageSize)

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-black" />
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-black dark:text-white">子用户管理</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">容器分配的子用户列表，共 {users.length} 个</p>
      </div>

      <div className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {users.length === 0 ? (
          <div className="flex flex-col items-center justify-center px-6 py-16 text-center">
            <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-lg bg-gray-100 dark:bg-gray-800">
              <UserCog className="h-7 w-7 text-gray-400" />
            </div>
            <div className="text-sm font-medium text-gray-700 dark:text-gray-300">暂无子用户</div>
          </div>
        ) : (
          <table className="w-full min-w-[820px] text-sm">
            <thead className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-xs text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-3 text-left font-medium w-12">#</th>
                <th className="px-4 py-3 text-left font-medium">容器名称</th>
                <th className="px-4 py-3 text-left font-medium">UUID</th>
                <th className="px-4 py-3 text-left font-medium">最后登录</th>
                <th className="px-4 py-3 text-center font-medium">操作</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {users.map((user, index) => (
                <tr key={user.id} className="hover:bg-gray-50 dark:hover:bg-gray-800">
                  <td className="px-4 py-3 text-gray-400 dark:text-gray-500">{index + 1}</td>
                  <td className="px-4 py-3 font-medium text-black dark:text-white">{user.container_name || '-'}</td>
                  <td className="px-4 py-3 font-mono text-xs text-gray-600 dark:text-gray-400">{user.container_uuid || '-'}</td>
                  <td className="px-4 py-3 text-gray-600 dark:text-gray-400">
                    {user.last_login ? (
                      <div>
                        <div className="text-xs">{user.last_login}</div>
                        <div className="text-xs text-gray-400 dark:text-gray-500">{user.last_login_ip}</div>
                      </div>
                    ) : (
                      <span className="text-gray-400">从未登录</span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center justify-center gap-1">
                      <button
                        onClick={() => setPasswordUser(user)}
                        className="inline-flex items-center gap-1 px-2 py-1.5 rounded text-xs text-amber-600 hover:bg-amber-50 dark:hover:bg-amber-900/30 transition-colors"
                        title="查看密码"
                      >
                        <KeyRound className="w-3.5 h-3.5" />
                        查看密码
                      </button>
                      <button
                        onClick={() => showAuditLogs(user)}
                        className="inline-flex items-center gap-1 px-2 py-1.5 rounded text-xs text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/30 transition-colors"
                        title="查看操作日志"
                      >
                        <ScrollText className="w-3.5 h-3.5" />
                        操作日志
                      </button>
                      <button
                        onClick={() => showLoginLogs(user)}
                        className="inline-flex items-center gap-1 px-2 py-1.5 rounded text-xs text-green-600 hover:bg-green-50 dark:hover:bg-green-900/30 transition-colors"
                        title="查看登录日志"
                      >
                        <LogIn className="w-3.5 h-3.5" />
                        登录日志
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {passwordUser && (
        <div className="fixed inset-0 bg-black/50 dark:bg-black/70 flex items-center justify-center z-50 p-4">
          <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 shadow-xl w-full max-w-lg overflow-hidden">
            <div className="flex items-center justify-between gap-3 px-5 py-3 border-b border-gray-200 dark:border-gray-700">
              <h3 className="text-sm font-semibold text-black dark:text-white">查看密码</h3>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => rotatePassword(passwordUser)}
                  disabled={rotatingPassword}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded text-xs text-amber-700 bg-amber-50 hover:bg-amber-100 dark:text-amber-300 dark:bg-amber-900/30 dark:hover:bg-amber-900/50 disabled:opacity-50"
                  title="轮换密码"
                >
                  <RefreshCw className={`w-3.5 h-3.5 ${rotatingPassword ? 'animate-spin' : ''}`} />
                  {rotatingPassword ? '轮换中...' : '轮换密码'}
                </button>
                <button onClick={() => setPasswordUser(null)} className="p-1 text-gray-400 hover:text-black dark:hover:text-white rounded">
                  <X className="w-4 h-4" />
                </button>
              </div>
            </div>
            <div className="p-5">
              <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4 text-sm space-y-3">
                <div className="flex items-start justify-between gap-3">
                  <span className="shrink-0 text-gray-500 dark:text-gray-400">用户</span>
                  <span className="min-w-0 text-right font-medium text-black dark:text-white break-all">{passwordUser.username}</span>
                </div>
                <div className="flex items-start justify-between gap-3">
                  <span className="shrink-0 text-gray-500 dark:text-gray-400">地址</span>
                  <div className="flex min-w-0 items-center gap-1">
                    <span className="font-mono text-xs text-black dark:text-white break-all">{managementUrl(passwordUser)}</span>
                    <button onClick={() => copyText(managementUrl(passwordUser))} className="shrink-0 p-0.5 text-gray-400 hover:text-black dark:hover:text-white rounded" title="复制">
                      <Copy className="w-3 h-3" />
                    </button>
                  </div>
                </div>
                <div className="flex items-start justify-between gap-3">
                  <span className="shrink-0 text-gray-500 dark:text-gray-400">密码</span>
                  <div className="flex min-w-0 items-center gap-1">
                    <span className="font-mono text-xs text-black dark:text-white break-all">
                      {passwordUser.password || '未保存，请轮换生成新密码'}
                    </span>
                    {passwordUser.password && (
                      <button onClick={() => copyText(passwordUser.password || '')} className="shrink-0 p-0.5 text-gray-400 hover:text-black dark:hover:text-white rounded" title="复制">
                        <Copy className="w-3 h-3" />
                      </button>
                    )}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Log Modal */}
      {(auditLogs || loginLogs) && (
        <div className="fixed inset-0 bg-black/50 dark:bg-black/70 flex items-center justify-center z-50 p-4">
          <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 shadow-xl w-full max-w-3xl max-h-[85vh] overflow-hidden flex flex-col">
            <div className="flex items-center justify-between px-5 py-3 border-b border-gray-200 dark:border-gray-700">
              <h3 className="text-sm font-semibold text-black dark:text-white">{modalTitle}</h3>
              <button onClick={closeModal} className="p-1 text-gray-400 hover:text-black dark:hover:text-white rounded">
                <X className="w-4 h-4" />
              </button>
            </div>
            <div className="overflow-auto flex-1">
              {auditLogs && (
                <table className="w-full text-sm">
                  <thead className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-xs text-gray-500 dark:text-gray-400 sticky top-0">
                    <tr>
                      <th className="px-4 py-2 text-left">操作时间</th>
                      <th className="px-4 py-2 text-left">操作</th>
                      <th className="px-4 py-2 text-left">IP</th>
                      <th className="px-4 py-2 text-left">UA</th>
                      <th className="px-4 py-2 text-center">结果</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                    {auditLogs.length === 0 ? (
                      <tr><td colSpan={5} className="px-4 py-8 text-center text-gray-400">暂无操作日志</td></tr>
                    ) : currentAuditLogs?.map((log, i) => (
                      <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-800">
                        <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-400 whitespace-nowrap">{log.time}</td>
                        <td className="px-4 py-2 text-xs text-gray-700 dark:text-gray-300">{log.action}</td>
                        <td className="px-4 py-2 text-xs font-mono text-gray-500 dark:text-gray-400">{log.ip || '-'}</td>
                        <td className="px-4 py-2 text-xs text-gray-500 dark:text-gray-400 max-w-[200px] truncate" title={log.user_agent}>{log.user_agent || '-'}</td>
                        <td className="px-4 py-2 text-center">
                          {log.success !== undefined ? (
                            log.success ? (
                              <span className="inline-flex px-2 py-0.5 rounded text-xs bg-green-50 text-green-700 dark:bg-green-900/30 dark:text-green-400">成功</span>
                            ) : (
                              <span className="inline-flex px-2 py-0.5 rounded text-xs bg-red-50 text-red-600 dark:bg-red-900/30 dark:text-red-400" title={log.error}>{log.error ? '失败' : '失败'}</span>
                            )
                          ) : (
                            <span className="text-gray-400">-</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              {loginLogs && (
                <table className="w-full text-sm">
                  <thead className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-xs text-gray-500 dark:text-gray-400 sticky top-0">
                    <tr>
                      <th className="px-4 py-2 text-left">登录时间</th>
                      <th className="px-4 py-2 text-left">登录 IP</th>
                      <th className="px-4 py-2 text-left">UA</th>
                      <th className="px-4 py-2 text-center">结果</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                    {loginLogs.length === 0 ? (
                      <tr><td colSpan={4} className="px-4 py-8 text-center text-gray-400">暂无登录日志</td></tr>
                    ) : currentLoginLogs?.map((log, i) => (
                      <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-800">
                        <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-400 whitespace-nowrap">{log.time}</td>
                        <td className="px-4 py-2 text-xs font-mono text-gray-500 dark:text-gray-400">{log.ip}</td>
                        <td className="px-4 py-2 text-xs text-gray-500 dark:text-gray-400 max-w-[250px] truncate" title={log.user_agent}>{log.user_agent}</td>
                        <td className="px-4 py-2 text-center">
                          {log.success ? (
                            <span className="inline-flex px-2 py-0.5 rounded text-xs bg-green-50 text-green-700 dark:bg-green-900/30 dark:text-green-400">成功</span>
                          ) : (
                            <span className="inline-flex px-2 py-0.5 rounded text-xs bg-red-50 text-red-600 dark:bg-red-900/30 dark:text-red-400">失败</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
            {currentLogTotal > 0 && (
              <div className="flex flex-wrap items-center justify-between gap-3 border-t border-gray-200 dark:border-gray-700 px-5 py-3">
                <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span>
                    显示 {logStart + 1}-{Math.min(logStart + logPageSize, currentLogTotal)} / {currentLogTotal}
                  </span>
                  <select
                    value={logPageSize}
                    onChange={(event) => {
                      setLogPageSize(Number(event.target.value))
                      setLogPage(1)
                    }}
                    className="h-7 rounded border border-gray-300 bg-white px-2 text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
                  >
                    <option value={10}>10 / 页</option>
                    <option value={20}>20 / 页</option>
                    <option value={50}>50 / 页</option>
                  </select>
                </div>
                <div className="flex items-center gap-1">
                  <button onClick={() => setLogPage(1)} disabled={currentLogPage === 1} className="rounded border border-gray-200 px-2.5 py-1.5 text-xs text-gray-600 hover:bg-gray-50 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800">首页</button>
                  <button onClick={() => setLogPage((page) => Math.max(1, page - 1))} disabled={currentLogPage === 1} className="rounded border border-gray-200 px-2.5 py-1.5 text-xs text-gray-600 hover:bg-gray-50 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800">上一页</button>
                  <span className="px-2 text-xs text-gray-500 dark:text-gray-400">{currentLogPage} / {logTotalPages}</span>
                  <button onClick={() => setLogPage((page) => Math.min(logTotalPages, page + 1))} disabled={currentLogPage === logTotalPages} className="rounded border border-gray-200 px-2.5 py-1.5 text-xs text-gray-600 hover:bg-gray-50 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800">下一页</button>
                  <button onClick={() => setLogPage(logTotalPages)} disabled={currentLogPage === logTotalPages} className="rounded border border-gray-200 px-2.5 py-1.5 text-xs text-gray-600 hover:bg-gray-50 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800">末页</button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
