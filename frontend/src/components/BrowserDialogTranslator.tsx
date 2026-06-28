import { useEffect } from 'react'
import { useLanguage } from '../contexts/LanguageContext'

export default function BrowserDialogTranslator() {
  const { t } = useLanguage()

  useEffect(() => {
    const originalAlert = window.alert
    const originalConfirm = window.confirm
    window.alert = (message?: unknown) => originalAlert(t(String(message ?? '')))
    window.confirm = (message?: string) => originalConfirm(t(String(message ?? '')))
    return () => {
      window.alert = originalAlert
      window.confirm = originalConfirm
    }
  }, [t])

  return null
}
