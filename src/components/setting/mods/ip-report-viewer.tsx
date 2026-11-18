import { ContentCopyRounded } from '@mui/icons-material'
import {
  Box,
  List,
  ListItem,
  ListItemText,
  TextField,
  Typography,
} from '@mui/material'
import { useLockFn } from 'ahooks'
import type { Ref } from 'react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { BaseDialog, DialogRef, Switch, TooltipIcon } from '@/components/base'
import { useVerge } from '@/hooks/use-verge'
import { showNotice } from '@/services/notice-service'

import { useSettingDialog } from '../settings-search-context'

const INSTALL_SCRIPT_URL =
  'https://raw.githubusercontent.com/xjblszyy/clash-verge-rev/dev/docs/ip-report/install.sh'

const randomPort = () => 20000 + Math.floor(Math.random() * 40000)

const randomPath = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) =>
    b.toString(16).padStart(2, '0'),
  ).join('')

export function IpReportViewer({ ref }: { ref?: Ref<DialogRef> }) {
  const { t } = useTranslation()
  const { verge, patchVerge } = useVerge()

  const [open, setOpen] = useState(false)
  const [values, setValues] = useState({
    enable: false,
    port: '',
    path: '',
  })
  const [proxyPorts, setProxyPorts] = useState('443/tcp')

  useSettingDialog(ref, 'ip-report-viewer', open, () => ({
    open: () => {
      setOpen(true)
      setValues({
        enable: verge?.enable_ip_report ?? false,
        port: (verge?.ip_report_port ?? randomPort()).toString(),
        path: verge?.ip_report_path || randomPath(),
      })
    },
    close: () => setOpen(false),
  }))

  const installCommand = `curl -fsSL ${INSTALL_SCRIPT_URL} | sudo bash -s -- --ports ${proxyPorts.replace(/\s+/g, '')} --http-port ${values.port} --path ${values.path.trim()}`

  const onCopy = () => {
    navigator.clipboard.writeText(installCommand).then(() => {
      showNotice.success(
        'shared.feedback.notifications.common.copySuccess',
        1000,
      )
    })
  }

  const onSave = useLockFn(async () => {
    const port = Number(values.port)
    try {
      await patchVerge({
        enable_ip_report: values.enable,
        ip_report_port:
          Number.isInteger(port) && port > 0 && port < 65536 ? port : null,
        ip_report_path: values.path.trim(),
      })
      setOpen(false)
    } catch (err) {
      showNotice.error(err)
    }
  })

  return (
    <BaseDialog
      open={open}
      title={t('settings.modals.ipReport.title')}
      contentSx={{ width: 520 }}
      okBtn={t('shared.actions.save')}
      cancelBtn={t('shared.actions.cancel')}
      onClose={() => setOpen(false)}
      onCancel={() => setOpen(false)}
      onOk={onSave}
    >
      <span data-settings-dialog="ip-report-viewer" />
      <List>
        <ListItem
          data-setting-target="settings.modals.ipReport.toggles.enable"
          sx={{ padding: '5px 2px' }}
        >
          <ListItemText
            primary={t('settings.modals.ipReport.toggles.enable')}
          />
          <Switch
            edge="end"
            checked={values.enable}
            onChange={(_, c) => setValues((v) => ({ ...v, enable: c }))}
          />
        </ListItem>

        <ListItem
          data-setting-target="settings.modals.ipReport.fields.port"
          sx={{ padding: '5px 2px' }}
        >
          <ListItemText primary={t('settings.modals.ipReport.fields.port')} />
          <TextField
            autoComplete="off"
            size="small"
            type="number"
            sx={{ width: 150 }}
            value={values.port}
            onChange={(e) => setValues((v) => ({ ...v, port: e.target.value }))}
          />
        </ListItem>

        <ListItem
          data-setting-target="settings.modals.ipReport.fields.path"
          sx={{ padding: '5px 2px' }}
        >
          <ListItemText primary={t('settings.modals.ipReport.fields.path')} />
          <TextField
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck="false"
            size="small"
            sx={{ width: 300 }}
            value={values.path}
            onChange={(e) => setValues((v) => ({ ...v, path: e.target.value }))}
          />
        </ListItem>

        <ListItem sx={{ padding: '5px 2px' }}>
          <Typography
            variant="body2"
            color="text.secondary"
            sx={{ fontStyle: 'italic' }}
          >
            {t('settings.modals.ipReport.messages.hint')}
          </Typography>
        </ListItem>

        <ListItem
          data-setting-target="settings.modals.ipReport.fields.installCommand"
          sx={{ padding: '5px 2px', display: 'block' }}
        >
          <ListItemText
            primary={t('settings.modals.ipReport.fields.installCommand')}
            secondary={t('settings.modals.ipReport.messages.installHint')}
          />
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 1 }}>
            <Typography variant="body2" sx={{ flexShrink: 0 }}>
              {t('settings.modals.ipReport.fields.proxyPorts')}
            </Typography>
            <TextField
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck="false"
              size="small"
              fullWidth
              placeholder="443/tcp,8443/udp"
              value={proxyPorts}
              onChange={(e) => setProxyPorts(e.target.value)}
            />
          </Box>
          <Box
            sx={{ display: 'flex', alignItems: 'flex-start', gap: 1, mt: 1 }}
          >
            <TextField
              size="small"
              fullWidth
              multiline
              value={installCommand}
              slotProps={{
                input: {
                  readOnly: true,
                  sx: { fontFamily: 'monospace', fontSize: 12 },
                },
              }}
            />
            <TooltipIcon
              icon={ContentCopyRounded}
              title={t('settings.modals.ipReport.actions.copyCommand')}
              onClick={onCopy}
            />
          </Box>
        </ListItem>
      </List>
    </BaseDialog>
  )
}
