import { useState, useCallback, createContext, useContext, ReactNode } from 'react'
import { AlertTriangle, CheckCircle, X } from 'lucide-react'
import { useLanguage } from '../contexts/LanguageContext'

type DialogType = 'confirm' | 'alert'

interface DialogState {
  open: boolean
  type: DialogType
  title: string
  message: string
  resolve?: (value: boolean) => void
}

interface DialogContextType {
  confirm: (title: string, message: string) => Promise<boolean>
  alert: (title: string, message: string) => Promise<void>
}

const DialogContext = createContext<DialogContextType | undefined>(undefined)

export function DialogProvider({ children }: { children: ReactNode }) {
  const [dialog, setDialog] = useState<DialogState>({ open: false, type: 'alert', title: '', message: '' })
  const { t } = useLanguage()

  const confirm = useCallback((title: string, message: string) => {
    return new Promise<boolean>((resolve) => {
      setDialog({ open: true, type: 'confirm', title, message, resolve })
    })
  }, [])

  const alert = useCallback((title: string, message: string) => {
    return new Promise<void>((resolve) => {
      setDialog({ open: true, type: 'alert', title, message, resolve: () => resolve() })
    })
  }, [])

  const close = (result: boolean) => {
    dialog.resolve?.(result)
    setDialog({ open: false, type: 'alert', title: '', message: '' })
  }

  return (
    <DialogContext.Provider value={{ confirm, alert }}>
      {children}
      {dialog.open && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center bg-black/50 p-4">
          <div className="bg-white rounded-lg shadow-xl border border-gray-200 w-full max-w-sm overflow-hidden">
            <div className="flex items-center gap-3 px-5 py-4 border-b border-gray-100">
              <div className={`w-8 h-8 rounded-full flex items-center justify-center ${
                dialog.type === 'confirm' ? 'bg-amber-50 text-amber-600' : 'bg-gray-100 text-gray-600'
              }`}>
                {dialog.type === 'confirm' ? <AlertTriangle className="w-4 h-4" /> : <CheckCircle className="w-4 h-4" />}
              </div>
              <h3 className="text-sm font-semibold text-black flex-1">{t(dialog.title)}</h3>
              {dialog.type === 'alert' && (
                <button onClick={() => close(true)} className="p-1 text-gray-400 hover:text-black rounded">
                  <X className="w-4 h-4" />
                </button>
              )}
            </div>
            <div className="px-5 py-4">
              <p className="text-sm text-gray-600">{t(dialog.message)}</p>
            </div>
            <div className="flex justify-end gap-2 px-5 py-3 bg-gray-50 border-t border-gray-100">
              {dialog.type === 'confirm' && (
                <button
                  onClick={() => close(false)}
                  className="px-4 py-2 text-sm text-gray-700 hover:bg-gray-200 rounded-md transition-colors"
                >
                  {t('取消')}
                </button>
              )}
              <button
                onClick={() => close(true)}
                className={`px-4 py-2 text-sm rounded-md transition-colors ${
                  dialog.type === 'confirm'
                    ? 'bg-black text-white hover:bg-gray-800'
                    : 'bg-black text-white hover:bg-gray-800'
                }`}
              >
                {dialog.type === 'confirm' ? t('确认') : t('确定')}
              </button>
            </div>
          </div>
        </div>
      )}
    </DialogContext.Provider>
  )
}

export function useDialog() {
  const ctx = useContext(DialogContext)
  if (!ctx) throw new Error('useDialog must be used within DialogProvider')
  return ctx
}
