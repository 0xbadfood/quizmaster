export function apiErrorMessage(detail, fallback) {
  if (typeof detail === 'string' && detail.trim()) return detail
  if (Array.isArray(detail)) {
    const messages = detail.map((item) => {
      if (typeof item === 'string') return item
      if (!item || typeof item !== 'object') return String(item)
      const location = Array.isArray(item.loc)
        ? item.loc.filter((part) => part !== 'body').join('.')
        : ''
      const message = item.msg || item.message || item.detail
      if (message) return location ? `${location}: ${message}` : String(message)
      return JSON.stringify(item)
    }).filter(Boolean)
    if (messages.length) return messages.join('; ')
  }
  if (detail && typeof detail === 'object') {
    const message = detail.message || detail.error || detail.detail
    if (typeof message === 'string' && message.trim()) return message
    try { return JSON.stringify(detail) } catch { /* use fallback */ }
  }
  return fallback
}

export async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: 'include',
    ...options,
    headers: {
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers,
    },
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    const error = new Error(apiErrorMessage(payload.detail, `Request failed (${response.status})`))
    error.status = response.status
    throw error
  }
  return payload
}

export function post(path, body = {}) {
  return api(path, { method: 'POST', body: JSON.stringify(body) })
}

export function patch(path, body = {}) {
  return api(path, { method: 'PATCH', body: JSON.stringify(body) })
}

export function del(path) {
  return api(path, { method: 'DELETE' })
}

export async function upload(path, file) {
  const response = await fetch(path, {
    method: 'POST',
    credentials: 'include',
    headers: { 'Content-Type': file.type || 'application/octet-stream' },
    body: file,
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(apiErrorMessage(payload.detail, `Upload failed (${response.status})`))
  return payload
}
