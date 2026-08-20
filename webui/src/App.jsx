import { useEffect, useMemo, useState } from 'react'
import {
  Activity,
  Archive,
  ArrowRight,
  AudioLines,
  BookOpenCheck,
  Bot,
  Check,
  CheckCircle2,
  ChevronDown,
  CircleAlert,
  CircleDashed,
  Database,
  Download,
  FileQuestion,
  Film,
  Gauge,
  Headphones,
  Image,
  KeyRound,
  Layers3,
  ListChecks,
  LockKeyhole,
  LoaderCircle,
  LogOut,
  Monitor,
  Pencil,
  Play,
  PackageCheck,
  Plus,
  RefreshCw,
  RotateCcw,
  Save,
  Server,
  Shuffle,
  Settings2,
  Smartphone,
  Sparkles,
  History,
  TestTube2,
  ThumbsUp,
  Upload,
  Volume2,
  Wifi,
  WifiOff,
  X,
} from 'lucide-react'
import { api, patch, post, upload } from './api.js'

const STAGES = [
  { id: 'overview', label: 'Overview', enabled: true },
  { id: 'questions', label: 'Questions', enabled: true },
  { id: 'sets', label: 'Sets', enabled: true },
  { id: 'visuals', label: 'Visuals', enabled: true },
  { id: 'audio', label: 'Audio', enabled: true },
  { id: 'publish', label: 'Publish', enabled: true },
  { id: 'video', label: 'Video', enabled: true },
]

const PROVIDER_META = {
  openai_compatible_llm: { label: 'OpenAI-compatible LLM', icon: Bot, tone: 'violet' },
  imagestudio: { label: 'ImageStudio', icon: Image, tone: 'blue' },
  openai_images: { label: 'OpenAI Images', icon: Sparkles, tone: 'coral' },
  vibevoice: { label: 'VibeVoice Chunk API', icon: AudioLines, tone: 'green' },
}

function LoginPage({ onLogin }) {
  const [username, setUsername] = useState('admin')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      await post('/api/auth/login', { username, password })
      onLogin()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy(false)
    }
  }

  return <main className="login-page">
    <div className="login-brand">
      <span className="logo-mark"><Layers3 size={26} /></span>
      <div><strong>Quiz Studio</strong><span>Content production</span></div>
    </div>
    <section className="login-panel">
      <p className="kicker">WELCOME BACK</p>
      <h1>Sign in to your studio</h1>
      <p className="login-copy">Private production access</p>
      <form onSubmit={submit}>
        <label>Username<input autoFocus autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} /></label>
        <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
        {error && <div className="inline-error"><CircleAlert size={16} />{error}</div>}
        <button className="button primary full" disabled={busy}>
          {busy ? <LoaderCircle className="spin" size={17} /> : <ArrowRight size={17} />}
          Sign in
        </button>
      </form>
    </section>
    <p className="login-foot">Private production environment</p>
  </main>
}

function AppHeader({ view, category, onView, onLogout, healthyProviders, totalProviders }) {
  return <header className="app-header">
    <div className="brand-lockup">
      <span className="logo-mark small"><Layers3 size={18} /></span>
      <div><strong>Quiz Studio</strong><span>Production workspace</span></div>
    </div>
    <div className="header-context">
      <span>{view === 'admin' ? 'Administration' : 'Categories'}</span>
      <strong>{view === 'admin' ? 'Provider connections' : category?.name || 'Select a category'}</strong>
      {view === 'workspace' && category?.bundle && <StatusBadge status={category.redeploy_required ? 'attention' : 'published'} label={category.redeploy_required ? 'Redeploy required' : `Live v${category.bundle.bundle_version}`} />}
    </div>
    <nav className="mode-switch" aria-label="Application area">
      <button className={view === 'workspace' ? 'active' : ''} onClick={() => onView('workspace')}><Gauge size={16} />Studio</button>
      <button className={view === 'admin' ? 'active' : ''} onClick={() => onView('admin')}><Settings2 size={16} />Admin</button>
    </nav>
    <div className="header-actions">
      <div className="service-summary" title={`${healthyProviders} of ${totalProviders} providers healthy`}>
        {healthyProviders === totalProviders && totalProviders > 0 ? <Wifi size={16} /> : <WifiOff size={16} />}
        <span>{healthyProviders}/{totalProviders} ready</span>
      </div>
      <button className="icon-button" title="Sign out" onClick={onLogout}><LogOut size={18} /></button>
    </div>
  </header>
}

function StatusBadge({ status, label }) {
  const text = label || status?.replaceAll('_', ' ') || 'Unknown'
  return <span className={`status-badge ${status || 'unchecked'}`}><span />{text}</span>
}

function CategorySidebar({ categories, selected, onSelect, loading, onRefresh, onCreate }) {
  const [query, setQuery] = useState('')
  const filtered = categories.filter((item) => item.name.toLowerCase().includes(query.trim().toLowerCase()))
  return <aside className="category-sidebar">
    <div className="sidebar-heading">
      <div><span>WORKSPACES</span><strong>Categories</strong></div>
      <div className="sidebar-heading-actions">
        <button className="icon-button quiet" title="Add category" onClick={onCreate}><Plus size={16} /></button>
        <button className="icon-button quiet" title="Refresh categories" onClick={() => onRefresh()}><RefreshCw size={16} /></button>
      </div>
    </div>
    <div className="sidebar-search"><input placeholder="Search categories" value={query} onChange={(event) => setQuery(event.target.value)} /></div>
    <div className="category-list">
      {loading && [...Array(5)].map((_, index) => <div className="category-skeleton" key={index} />)}
      {!loading && filtered.map((item) => <button className={`category-item ${selected === item.slug ? 'selected' : ''}`} key={item.slug} onClick={() => onSelect(item.slug)}>
        <span className="category-thumb">{item.thumbnail_url ? <img src={item.thumbnail_url} alt="" /> : <span>{item.name.slice(0, 2).toUpperCase()}</span>}</span>
        <span className="category-copy"><strong>{item.name}</strong><small>{item.redeploy_required ? 'Redeploy required' : item.bundle ? `Published v${item.bundle.bundle_version}` : item.production_status}</small></span>
        <span className={`category-state ${item.bundle ? 'published' : item.workspace_available ? 'production' : 'draft'}`} />
      </button>)}
      {!loading && !filtered.length && <div className="sidebar-empty">No matching categories</div>}
    </div>
    <div className="sidebar-footer"><Database size={15} /><span>{categories.length} category workspaces</span></div>
  </aside>
}

function StageNavigation({ active = 'overview', onStage }) {
  return <nav className="stage-navigation" aria-label="Category production stages">
    {STAGES.map((stage) => <button key={stage.id} className={stage.id === active ? 'active' : ''} disabled={!stage.enabled} title={!stage.enabled ? 'Not available' : stage.label} onClick={() => stage.enabled && onStage?.(stage.id)}>{stage.label}</button>)}
  </nav>
}

function Metric({ label, value, detail, icon: Icon }) {
  return <div className="metric"><span><Icon size={17} /></span><div><strong>{value}</strong><small>{label}</small><em>{detail}</em></div></div>
}

function OverviewWorkspace({ category, onStage, onEdit }) {
  if (!category) return <EmptyState icon={Layers3} title="Select a category" detail="Choose a category workspace from the sidebar." />
  const bankTotal = category.bank.beginner + category.bank.intermediate
  const setsTotal = category.sets.beginner + category.sets.intermediate
  return <div className="studio-layout">
    <section className="studio-canvas">
      <StageNavigation onStage={onStage} />
      <div className="canvas-scroll">
        <header className="category-masthead">
          <div>
            <div className="masthead-meta"><StatusBadge status={category.bundle ? 'published' : category.production_status} /><span>Ages {category.age_min}-{category.age_max}</span></div>
            <h1>{category.name}</h1>
            <p>{category.editorial_brief || category.description}</p>
          </div>
          <div className="masthead-actions">
            <button className="button secondary" onClick={onEdit}><Pencil size={14} />Edit metadata</button>
            <div className="masthead-version"><span>ACTIVE RELEASE</span><strong>{category.bundle ? `v${category.bundle.bundle_version}` : '-'}</strong><small>{category.bundle ? 'Available to the mobile app' : 'Not published'}</small></div>
          </div>
        </header>

        <div className="metric-strip">
          <Metric icon={FileQuestion} value={bankTotal} label="Bank questions" detail={`${category.bank.allocated} allocated`} />
          <Metric icon={Layers3} value={setsTotal} label="Quiz sets" detail={`${setsTotal * 10} allocated questions`} />
          <Metric icon={Image} value={category.answer_images.generated + category.category_images.generated} label="Generated visuals" detail={`${category.answer_images.pending_review + category.category_images.pending_review} awaiting review`} />
          <Metric icon={Volume2} value={category.audio_count} label="Narrated questions" detail="Question and explanation" />
        </div>

        <section className="readiness-section">
          <div className="section-heading"><div><p className="kicker">PRODUCTION READINESS</p><h2>Category pipeline</h2></div><span>Updated from the working artifacts</span></div>
          <div className="readiness-table">
            {category.stages.map((stage) => {
              const ratio = stage.target ? Math.min(100, Math.round(stage.current / stage.target * 100)) : (stage.current ? 100 : 0)
              return <div className="readiness-row" key={stage.id}>
                <StatusIcon status={stage.status} />
                <div className="readiness-name"><strong>{stage.label}</strong><small>{stage.detail}</small></div>
                <div className="readiness-progress"><span><i style={{ width: `${ratio}%` }} /></span><small>{ratio}%</small></div>
                <div className="readiness-count"><strong>{stage.current}</strong>{stage.target && <span>/ {stage.target}</span>}</div>
                <StatusBadge status={stage.status} />
              </div>
            })}
          </div>
        </section>

        <section className="difficulty-section">
          <div className="section-heading"><div><p className="kicker">CONTENT ALLOCATION</p><h2>Difficulty coverage</h2></div></div>
          <div className="difficulty-grid">
            {['beginner', 'intermediate'].map((difficulty) => <div className="difficulty-row" key={difficulty}>
              <span className={`difficulty-mark ${difficulty}`}>{difficulty === 'beginner' ? 'B' : 'I'}</span>
              <div><strong>{difficulty}</strong><small>{category.bank[difficulty]} bank questions</small></div>
              <div><strong>{category.sets[difficulty]}</strong><small>quiz sets</small></div>
              <CheckCircle2 size={19} />
            </div>)}
          </div>
        </section>
      </div>
    </section>
    <CategoryInspector category={category} onEdit={onEdit} />
  </div>
}

function QuestionBankWorkspace({ category, providers, onStage, onJob, refreshToken, onCategoryRefresh }) {
  const [filters, setFilters] = useState({ difficulty: 'all', state: 'all', review: 'all', q: '', page: 1 })
  const [query, setQuery] = useState('')
  const [payload, setPayload] = useState(null)
  const [selectedKey, setSelectedKey] = useState('')
  const [selected, setSelected] = useState(null)
  const [checked, setChecked] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [dialog, setDialog] = useState('')
  const metadataReady = category?.metadata?.ready !== false

  const queryString = useMemo(() => new URLSearchParams({ ...filters, q: query, page_size: 30 }).toString(), [filters, query])

  async function loadBank(preferredKey) {
    if (!category) return
    setLoading(true); setError('')
    try {
      const result = await api(`/api/studio/categories/${category.slug}/questions?${queryString}`)
      setPayload(result)
      setChecked([])
      const availableKeys = result.questions.map((item) => `${item.difficulty}/${item.question_id}`)
      const nextKey = preferredKey || (availableKeys.includes(selectedKey) ? selectedKey : availableKeys[0] || '')
      setSelectedKey(nextKey)
      if (!nextKey) setSelected(null)
    } catch (requestError) { setError(requestError.message) } finally { setLoading(false) }
  }

  async function loadSelected(key = selectedKey) {
    if (!key || !category) { setSelected(null); return }
    const [difficulty, questionId] = key.split('/')
    try { setSelected(await api(`/api/studio/categories/${category.slug}/questions/${difficulty}/${questionId}`)) } catch (requestError) { setError(requestError.message) }
  }

  useEffect(() => { const timer = window.setTimeout(() => setQuery(filters.q), 250); return () => window.clearTimeout(timer) }, [filters.q])
  useEffect(() => { loadBank() }, [category?.slug, queryString, refreshToken])
  useEffect(() => { loadSelected() }, [selectedKey, refreshToken])

  function changeFilter(key, value) { setFilters((current) => ({ ...current, [key]: value, page: 1 })) }
  function toggleChecked(key) { setChecked((current) => current.includes(key) ? current.filter((item) => item !== key) : [...current, key]) }

  async function bulkApprove() {
    const groups = checked.reduce((result, key) => { const [difficulty, questionId] = key.split('/'); (result[difficulty] ||= []).push(questionId); return result }, {})
    try {
      await Promise.all(Object.entries(groups).map(([difficulty, question_ids]) => post(`/api/studio/categories/${category.slug}/questions/bulk-review`, { difficulty, question_ids, status: 'approved' })))
      await loadBank(selectedKey); await loadSelected(); await onCategoryRefresh()
    } catch (requestError) { setError(requestError.message) }
  }

  async function changed(question) {
    const key = `${question.difficulty}/${question.question_id}`
    await loadBank(key); setSelected(question); await onCategoryRefresh()
  }

  const summary = payload?.summary
  return <div className="question-studio-layout">
    <section className="question-canvas">
      <StageNavigation active="questions" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">QUESTION BANK</p><h1>{category.name}</h1></div>
        <div className="question-actions">
          {!metadataReady && <span className="toolbar-gate"><CircleAlert size={14} />Metadata required</span>}
          {checked.length > 0 && <button className="button secondary" onClick={bulkApprove}><ThumbsUp size={15} />Approve {checked.length}</button>}
          <button className="button secondary" onClick={() => setDialog('import')}><Upload size={15} />Import</button>
          <button className="button primary" disabled={!metadataReady} title={!metadataReady ? 'Complete category metadata before generation' : 'Generate questions'} onClick={() => setDialog('generate')}><Sparkles size={15} />Generate</button>
        </div>
      </div>
      {summary && <div className="bank-summary">
        <BankStat value={summary.usable} label="Questions" detail={`${summary.target - summary.usable > 0 ? summary.target - summary.usable : 0} to target`} tone="blue" />
        <BankStat value={summary.approved} label="Approved" detail={`${summary.unreviewed} unreviewed`} tone="green" />
        <BankStat value={summary.available} label="Reserves" detail={`${summary.allocated} allocated`} tone="violet" />
        <BankStat value={summary.needs_edit + summary.validation_issues} label="Attention" detail={`${summary.review_rejected} rejected`} tone="amber" />
      </div>}
      <div className="bank-filters">
        <div className="bank-search"><FileQuestion size={15} /><input aria-label="Search question bank" placeholder="Search questions, choices, or IDs" value={filters.q} onChange={(event) => changeFilter('q', event.target.value)} /></div>
        <select aria-label="Difficulty filter" value={filters.difficulty} onChange={(event) => changeFilter('difficulty', event.target.value)}><option value="all">All difficulties</option><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option></select>
        <select aria-label="Allocation filter" value={filters.state} onChange={(event) => changeFilter('state', event.target.value)}><option value="all">All allocations</option><option value="available">Reserve</option><option value="allocated">Allocated</option><option value="rejected">Rejected</option></select>
        <select aria-label="Review filter" value={filters.review} onChange={(event) => changeFilter('review', event.target.value)}><option value="all">All reviews</option><option value="unreviewed">Unreviewed</option><option value="approved">Approved</option><option value="needs_edit">Needs edit</option><option value="rejected">Rejected</option></select>
        <button className="icon-button" title="Refresh questions" onClick={() => loadBank()}><RefreshCw size={16} /></button>
      </div>
      <div className="question-table-shell">
        <div className="question-table-head"><span /><span>Question</span><span>Answer</span><span>Difficulty</span><span>Review</span></div>
        <div className="question-table-body">
          {loading && [...Array(8)].map((_, index) => <div className="question-row-skeleton" key={index} />)}
          {!loading && payload?.questions.map((question) => {
            const key = `${question.difficulty}/${question.question_id}`
            const answer = question.choices.find((choice) => choice.choice_id === question.correct_choice_id)?.label
            return <div role="button" tabIndex="0" className={`question-row ${selectedKey === key ? 'selected' : ''}`} onClick={() => setSelectedKey(key)} onKeyDown={(event) => event.key === 'Enter' && setSelectedKey(key)} key={key}>
              <input type="checkbox" aria-label={`Select ${question.question_id}`} checked={checked.includes(key)} onClick={(event) => event.stopPropagation()} onChange={() => toggleChecked(key)} />
              <span className="question-main"><strong>{question.question}</strong><small><code>{question.question_id}</code>{question.locked ? <><LockKeyhole size={11} />{question.set_id}</> : 'Reserve question'}{question.validation_issues.length > 0 && <span className="issue-count"><CircleAlert size={11} />{question.validation_issues.length}</span>}</small></span>
              <span className="answer-cell">{answer}</span>
              <span className={`difficulty-pill ${question.difficulty}`}>{question.difficulty}</span>
              <StatusBadge status={question.review_status === 'needs_edit' ? 'attention' : question.review_status} />
            </div>
          })}
          {!loading && !payload?.questions.length && <EmptyState icon={FileQuestion} title="No matching questions" detail="Adjust the filters or add questions to this bank." />}
        </div>
        {payload && <div className="question-pagination"><span>{payload.pagination.total} matching questions</span><div><button className="button secondary" disabled={filters.page <= 1} onClick={() => setFilters((current) => ({ ...current, page: current.page - 1 }))}>Previous</button><span>Page {payload.pagination.page} of {payload.pagination.pages}</span><button className="button secondary" disabled={filters.page >= payload.pagination.pages} onClick={() => setFilters((current) => ({ ...current, page: current.page + 1 }))}>Next</button></div></div>}
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    <QuestionInspector category={category} question={selected} onChanged={changed} />
    {dialog === 'import' && <QuestionImportDialog category={category} onClose={() => setDialog('')} onImported={async () => { setDialog(''); await loadBank(); await onCategoryRefresh() }} />}
    {dialog === 'generate' && <QuestionGenerateDialog category={category} providers={providers} summary={summary} onClose={() => setDialog('')} onQueued={(job) => { setDialog(''); onJob(job) }} />}
  </div>
}

function BankStat({ value, label, detail, tone }) {
  return <div className={`bank-stat ${tone}`}><strong>{value}</strong><span>{label}</span><small>{detail}</small></div>
}

function QuestionInspector({ category, question, onChanged }) {
  const [form, setForm] = useState(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => { setForm(question ? { question: question.question, choices: question.choices.map((choice) => ({ object_key: choice.object_key, label: choice.label })), correct_choice_id: question.correct_choice_id, explanation: question.explanation, notes: question.review_notes || '' } : null); setNotice('') }, [question])
  if (!question || !form) return <aside className="question-inspector"><div className="inspector-title"><div><BookOpenCheck size={16} /><strong>Question editor</strong></div></div><EmptyState icon={FileQuestion} title="Select a question" detail="Question details and review controls appear here." /></aside>
  const locked = question.locked
  function changeChoice(index, key, value) { setForm((current) => ({ ...current, choices: current.choices.map((choice, choiceIndex) => choiceIndex === index ? { ...choice, [key]: value } : choice) })) }
  async function save() {
    setBusy(true); setNotice('')
    try { const updated = await patch(`/api/studio/categories/${category.slug}/questions/${question.difficulty}/${question.question_id}`, { question: form.question, choices: form.choices, correct_choice_id: form.correct_choice_id, explanation: form.explanation }); setNotice('Question saved'); await onChanged(updated) } catch (error) { setNotice(error.message) } finally { setBusy(false) }
  }
  async function review(status) {
    setBusy(true); setNotice('')
    try { const updated = await post(`/api/studio/categories/${category.slug}/questions/${question.difficulty}/${question.question_id}/review`, { status, notes: form.notes }); setNotice(status === 'approved' ? 'Question approved' : status === 'rejected' ? 'Question rejected' : 'Marked for editing'); await onChanged(updated) } catch (error) { setNotice(error.message) } finally { setBusy(false) }
  }
  return <aside className="question-inspector">
    <div className="inspector-title"><div><Pencil size={16} /><strong>Question editor</strong></div><StatusBadge status={question.review_status === 'needs_edit' ? 'attention' : question.review_status} /></div>
    <div className="question-inspector-scroll">
      <div className="question-editor-meta"><span className={`difficulty-pill ${question.difficulty}`}>{question.difficulty}</span><code>{question.question_id}</code>{locked && <span><LockKeyhole size={12} />Allocated</span>}</div>
      {locked && <div className="locked-notice"><LockKeyhole size={16} /><span><strong>Content locked</strong><small>Published set {question.set_id} references this question.</small></span></div>}
      {question.validation_issues.length > 0 && <div className="validation-list">{question.validation_issues.map((issue) => <span key={issue}><CircleAlert size={13} />{issue}</span>)}</div>}
      <label>Question<textarea rows="4" disabled={locked} value={form.question} onChange={(event) => setForm({ ...form, question: event.target.value })} /></label>
      <fieldset className="choice-editor" disabled={locked}><legend>Answer choices</legend>{form.choices.map((choice, index) => <div className={`choice-edit-row ${form.correct_choice_id === `choice${index + 1}` ? 'correct' : ''}`} key={index}><input type="radio" name="correct-answer" title="Correct answer" checked={form.correct_choice_id === `choice${index + 1}`} onChange={() => setForm({ ...form, correct_choice_id: `choice${index + 1}` })} /><input aria-label={`Choice ${index + 1} label`} value={choice.label} onChange={(event) => changeChoice(index, 'label', event.target.value)} /><input aria-label={`Choice ${index + 1} key`} value={choice.object_key} onChange={(event) => changeChoice(index, 'object_key', event.target.value)} /></div>)}</fieldset>
      <label>Explanation<textarea rows="5" disabled={locked} value={form.explanation} onChange={(event) => setForm({ ...form, explanation: event.target.value })} /></label>
      {!locked && <button className="button secondary full" disabled={busy} onClick={save}>{busy ? <LoaderCircle className="spin" size={15} /> : <Save size={15} />}Save content</button>}
      <div className="review-section"><span className="inspector-label">REVIEW DECISION</span><label>Reviewer notes<textarea rows="3" value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} /></label><div className="review-actions"><button className="button approve" disabled={busy} onClick={() => review('approved')}><Check size={15} />Approve</button><button className="button secondary" disabled={busy} onClick={() => review('needs_edit')}><Pencil size={14} />Needs edit</button><button className="button danger" disabled={busy || locked} onClick={() => review('rejected')}><Archive size={14} />Reject</button></div></div>
      {notice && <div className={notice.includes('approved') || notice.includes('saved') ? 'form-notice success inspector-notice' : 'form-notice inspector-notice'}>{notice}</div>}
      {question.revisions?.length > 0 && <div className="revision-list"><span className="inspector-label">RECENT HISTORY</span>{question.revisions.slice(0, 5).map((revision) => <div key={revision.id}><strong>{revision.action}</strong><small>{new Date(revision.created_at).toLocaleString()}</small></div>)}</div>}
    </div>
  </aside>
}

function QuestionImportDialog({ category, onClose, onImported }) {
  const [difficulty, setDifficulty] = useState('beginner')
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function chooseFile(event) { const file = event.target.files?.[0]; if (file) setText(await file.text()) }
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    try {
      const parsed = JSON.parse(text); const questions = Array.isArray(parsed) ? parsed : parsed.questions
      if (!Array.isArray(questions)) throw new Error('JSON must be an array or contain a questions array')
      const result = await post(`/api/studio/categories/${category.slug}/questions/import`, { difficulty, questions })
      if (!result.accepted) throw new Error(result.rejections?.[0]?.reasons?.join(' ') || 'No valid questions were found')
      await onImported(result)
    } catch (requestError) { setError(requestError.message); setBusy(false) }
  }
  return <div className="dialog-backdrop"><section className="dialog question-dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">QUESTION BANK</p><h2>Import questions</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}><div className="dialog-grid"><label>Difficulty<select value={difficulty} onChange={(event) => setDifficulty(event.target.value)}><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option></select></label><label>JSON file<input className="file-input" type="file" accept="application/json,.json" onChange={chooseFile} /></label></div><label>Question JSON<textarea rows="12" required spellCheck="false" placeholder='{"questions": [...]}' value={text} onChange={(event) => setText(event.target.value)} /></label>{error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}<div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy}>{busy ? <LoaderCircle className="spin" size={15} /> : <Upload size={15} />}Validate and import</button></div></form></section></div>
}

function QuestionGenerateDialog({ category, providers, summary, onClose, onQueued }) {
  const llms = providers.filter((provider) => ['openai_compatible_llm', 'openai_images'].includes(provider.provider_type) && provider.enabled).sort((left, right) => {
    const rank = (provider) => provider.provider_type === 'openai_images' && provider.has_secret ? 0 : provider.provider_type === 'openai_compatible_llm' ? 1 : 2
    return rank(left) - rank(right)
  })
  function questionModel(provider) { return provider?.provider_type === 'openai_images' ? provider.settings.question_model || 'gpt-5.6-luna' : provider?.default_model || provider?.discovered_models?.[0] || '' }
  function providerLabel(provider) { return provider.provider_type === 'openai_images' ? `${provider.name} (OpenAI API)` : provider.name }
  const defaultDifficulty = summary?.intermediate < 120 ? 'intermediate' : 'beginner'
  const [form, setForm] = useState({ difficulty: defaultDifficulty, count: Math.max(1, Math.min(20, 120 - (summary?.[defaultDifficulty] || 0))), provider_id: llms[0]?.id || '', model: questionModel(llms[0]) })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function submit(event) { event.preventDefault(); setBusy(true); setError(''); try { onQueued(await post(`/api/studio/categories/${category.slug}/questions/generate`, { ...form, count: Number(form.count) })) } catch (requestError) { setError(requestError.message); setBusy(false) } }
  function selectProvider(providerId) { const provider = llms.find((item) => item.id === providerId); setForm({ ...form, provider_id: providerId, model: questionModel(provider) }) }
  const selectedProvider = llms.find((provider) => provider.id === form.provider_id)
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">QUESTION BANK</p><h2>Generate questions</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}><label>LLM connection<select required value={form.provider_id} onChange={(event) => selectProvider(event.target.value)}><option value="" disabled>Select a provider</option>{llms.map((provider) => <option value={provider.id} key={provider.id}>{providerLabel(provider)}</option>)}</select></label><label>Model<input required list="generation-models" placeholder="Model ID" value={form.model} onChange={(event) => setForm({ ...form, model: event.target.value })} /><datalist id="generation-models">{selectedProvider?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label><div className="dialog-grid"><label>Difficulty<select value={form.difficulty} onChange={(event) => setForm({ ...form, difficulty: event.target.value })}><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option></select></label><label>Questions to add<input type="number" min="1" max="30" value={form.count} onChange={(event) => setForm({ ...form, count: event.target.value })} /></label></div>{!llms.length && <div className="inline-error"><CircleAlert size={15} />Configure an OpenAI API or OpenAI-compatible LLM connection in Admin first.</div>}{error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}<div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !llms.length || !form.model}>{busy ? <LoaderCircle className="spin" size={15} /> : <Sparkles size={15} />}Start generation</button></div></form></section></div>
}

function QuizSetsWorkspace({ category, providers, onStage, onJob, refreshToken, onCategoryRefresh }) {
  const [difficulty, setDifficulty] = useState('all')
  const [payload, setPayload] = useState(null)
  const [selectedKey, setSelectedKey] = useState('')
  const [selected, setSelected] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [dialog, setDialog] = useState(false)

  async function loadSets(preferredKey) {
    if (!category) return
    setLoading(true); setError('')
    try {
      const result = await api(`/api/studio/categories/${category.slug}/sets?difficulty=${difficulty}`)
      setPayload(result)
      const keys = result.sets.map((item) => `${item.difficulty}/${item.set_id}`)
      const nextKey = preferredKey || (keys.includes(selectedKey) ? selectedKey : keys[0] || '')
      setSelectedKey(nextKey)
      if (!nextKey) setSelected(null)
    } catch (requestError) { setError(requestError.message) } finally { setLoading(false) }
  }

  async function loadSelected(key = selectedKey) {
    if (!key || !category) { setSelected(null); return }
    const [setDifficulty, setId] = key.split('/')
    try { setSelected(await api(`/api/studio/categories/${category.slug}/sets/${setDifficulty}/${setId}`)) } catch (requestError) { setError(requestError.message) }
  }

  useEffect(() => { loadSets() }, [category?.slug, difficulty, refreshToken])
  useEffect(() => { loadSelected() }, [selectedKey, refreshToken])

  async function changed(updated) {
    const key = `${updated.difficulty}/${updated.set_id}`
    await loadSets(key); setSelected(updated); await onCategoryRefresh()
  }

  const summary = payload?.summary
  const capacity = summary ? Math.min(
    summary.selection_slots.beginner,
    summary.banks.beginner.selection_capacity,
  ) + Math.min(
    summary.selection_slots.intermediate,
    summary.banks.intermediate.selection_capacity,
  ) : 0
  return <div className="set-studio-layout">
    <section className="set-canvas">
      <StageNavigation active="sets" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">QUIZ SETS</p><h1>{category.name}</h1></div>
        <div className="question-actions"><button className="button primary" disabled={!capacity} onClick={() => setDialog(true)}><Shuffle size={15} />Select sets</button></div>
      </div>
      {summary && <div className="bank-summary">
        <BankStat value={summary.total} label="Quiz sets" detail={`${summary.beginner} beginner · ${summary.intermediate} intermediate`} tone="blue" />
        <BankStat value={summary.approved} label="Approved" detail={`${summary.unreviewed} unreviewed`} tone="green" />
        <BankStat value={capacity} label="Set capacity" detail="From current reserves" tone="violet" />
        <BankStat value={summary.needs_edit + summary.rejected + summary.validation_issues.length} label="Attention" detail={`${summary.rejected} rejected`} tone="amber" />
      </div>}
      <div className="set-filters">
        <div className="segmented-control" aria-label="Difficulty filter">{['all', 'beginner', 'intermediate'].map((item) => <button className={difficulty === item ? 'active' : ''} onClick={() => setDifficulty(item)} key={item}>{item}</button>)}</div>
        <span>{payload?.sets.length || 0} visible</span>
        <button className="icon-button" title="Refresh quiz sets" onClick={() => loadSets()}><RefreshCw size={16} /></button>
      </div>
      <div className="set-table-shell">
        <div className="set-table-head"><span>Set</span><span>Question coverage</span><span>Correct answers</span><span>Review</span></div>
        <div className="set-table-body">
          {loading && [...Array(7)].map((_, index) => <div className="set-row-skeleton" key={index} />)}
          {!loading && payload?.sets.map((quizSet) => {
            const key = `${quizSet.difficulty}/${quizSet.set_id}`
            return <button className={`set-row ${selectedKey === key ? 'selected' : ''}`} onClick={() => setSelectedKey(key)} key={key}>
              <span className="set-identity"><i className={`difficulty-mark ${quizSet.difficulty}`}>{quizSet.set_number}</i><span><strong>Set {quizSet.set_number}</strong><small>{quizSet.difficulty}</small></span></span>
              <span className="set-coverage"><strong>{quizSet.question_count} questions</strong><small>{quizSet.selection_model || 'Deterministic selection'}</small></span>
              <span className="set-answer-sample">{quizSet.answers.slice(0, 3).join(', ')}<small>+{Math.max(0, quizSet.answers.length - 3)} more</small></span>
              <StatusBadge status={quizSet.review_status === 'needs_edit' ? 'attention' : quizSet.review_status} />
            </button>
          })}
          {!loading && !payload?.sets.length && <EmptyState icon={ListChecks} title="No quiz sets" detail="Select sets from the available question reserves." />}
        </div>
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    <QuizSetInspector category={category} quizSet={selected} onChanged={changed} />
    {dialog && <QuizSetSelectionDialog category={category} providers={providers} summary={summary} onClose={() => setDialog(false)} onQueued={(job) => { setDialog(false); onJob(job) }} />}
  </div>
}

function QuizSetInspector({ category, quizSet, onChanged }) {
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => { setNotes(quizSet?.review_notes || ''); setNotice('') }, [quizSet])
  if (!quizSet) return <aside className="set-inspector"><div className="inspector-title"><div><ListChecks size={16} /><strong>Set review</strong></div></div><EmptyState icon={ListChecks} title="Select a quiz set" detail="Its ten questions and review controls appear here." /></aside>
  async function review(status) {
    setBusy(true); setNotice('')
    try {
      const updated = await post(`/api/studio/categories/${category.slug}/sets/${quizSet.difficulty}/${quizSet.set_id}/review`, { status, notes })
      setNotice(status === 'approved' ? 'Quiz set approved' : status === 'rejected' ? 'Quiz set rejected' : 'Marked for editing')
      await onChanged(updated)
    } catch (error) { setNotice(error.message) } finally { setBusy(false) }
  }
  return <aside className="set-inspector">
    <div className="inspector-title"><div><ListChecks size={16} /><strong>Set {quizSet.set_number}</strong></div><StatusBadge status={quizSet.review_status === 'needs_edit' ? 'attention' : quizSet.review_status} /></div>
    <div className="set-inspector-scroll">
      <div className="question-editor-meta"><span className={`difficulty-pill ${quizSet.difficulty}`}>{quizSet.difficulty}</span><code>{quizSet.set_id}</code></div>
      <ol className="set-question-list">{quizSet.questions.map((question) => <li key={question.question_id}><span>{question.question}</span><strong>{question.correct_answer}</strong></li>)}</ol>
      <div className="review-section"><span className="inspector-label">REVIEW DECISION</span><label>Reviewer notes<textarea rows="3" value={notes} onChange={(event) => setNotes(event.target.value)} /></label><div className="review-actions"><button className="button approve" disabled={busy} onClick={() => review('approved')}><Check size={15} />Approve</button><button className="button secondary" disabled={busy} onClick={() => review('needs_edit')}><Pencil size={14} />Needs edit</button><button className="button danger" disabled={busy} onClick={() => review('rejected')}><Archive size={14} />Reject</button></div></div>
      {notice && <div className={notice.includes('approved') ? 'form-notice success inspector-notice' : 'form-notice inspector-notice'}>{notice}</div>}
      {quizSet.revisions?.length > 0 && <div className="revision-list"><span className="inspector-label">RECENT HISTORY</span>{quizSet.revisions.slice(0, 5).map((revision) => <div key={revision.id}><strong>{revision.action}</strong><small>{new Date(revision.created_at).toLocaleString()}</small></div>)}</div>}
    </div>
  </aside>
}

function QuizSetSelectionDialog({ category, providers, summary, onClose, onQueued }) {
  const llms = providers.filter((provider) => provider.provider_type === 'openai_compatible_llm' && provider.enabled)
  const defaultDifficulty = ['beginner', 'intermediate'].find((item) => Math.min(summary?.selection_slots?.[item] || 0, summary?.banks?.[item]?.selection_capacity || 0) > 0) || 'beginner'
  const defaultProvider = llms[0]
  const defaultCount = Math.max(1, Math.min(5, summary?.selection_slots?.[defaultDifficulty] || 1, summary?.banks?.[defaultDifficulty]?.selection_capacity || 1))
  const [form, setForm] = useState({ difficulty: defaultDifficulty, count: defaultCount, provider_id: defaultProvider?.id || '', model: defaultProvider?.default_model || defaultProvider?.discovered_models?.[0] || '', strictness: 'strict', seed: 20260805 })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const selectedProvider = llms.find((provider) => provider.id === form.provider_id)
  const allowed = Math.min(summary?.selection_slots?.[form.difficulty] || 0, summary?.banks?.[form.difficulty]?.selection_capacity || 0)
  function changeDifficulty(value) { setForm((current) => ({ ...current, difficulty: value, count: Math.min(current.count, Math.max(1, Math.min(5, summary?.selection_slots?.[value] || 1, summary?.banks?.[value]?.selection_capacity || 1))) })) }
  function changeProvider(value) { const provider = llms.find((item) => item.id === value); setForm((current) => ({ ...current, provider_id: value, model: provider?.default_model || provider?.discovered_models?.[0] || '' })) }
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    try { onQueued(await post(`/api/studio/categories/${category.slug}/sets/select`, { ...form, count: Number(form.count), seed: Number(form.seed) })) } catch (requestError) { setError(requestError.message); setBusy(false) }
  }
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">QUIZ SETS</p><h2>Select from question bank</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <label>LLM connection<select required value={form.provider_id} onChange={(event) => changeProvider(event.target.value)}><option value="" disabled>Select a provider</option>{llms.map((provider) => <option value={provider.id} key={provider.id}>{provider.name}</option>)}</select></label>
    <label>Model<input required list="selection-models" value={form.model} onChange={(event) => setForm({ ...form, model: event.target.value })} /><datalist id="selection-models">{selectedProvider?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label>
    <div className="dialog-grid"><label>Difficulty<select value={form.difficulty} onChange={(event) => changeDifficulty(event.target.value)}><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option></select></label><label>Sets to create<input type="number" min="1" max={Math.max(1, allowed)} value={form.count} onChange={(event) => setForm({ ...form, count: event.target.value })} /></label></div>
    <div className="dialog-grid"><label>Selection policy<select value={form.strictness} onChange={(event) => setForm({ ...form, strictness: event.target.value })}><option value="strict">Strict</option><option value="balanced">Balanced</option></select></label><label>Seed<input type="number" min="0" max="2147483647" value={form.seed} onChange={(event) => setForm({ ...form, seed: event.target.value })} /></label></div>
    <div className="selection-capacity"><Database size={15} /><span><strong>{summary?.banks?.[form.difficulty]?.available || 0} reserve questions</strong><small>Can select up to {allowed} additional set{allowed === 1 ? '' : 's'}</small></span></div>
    {!llms.length && <div className="inline-error"><CircleAlert size={15} />Configure an OpenAI-compatible LLM connection in Admin first.</div>}{error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !llms.length || !allowed || Number(form.count) > allowed || !form.model}>{busy ? <LoaderCircle className="spin" size={15} /> : <Shuffle size={15} />}Start selection</button></div>
  </form></section></div>
}

const BACKGROUND_VISUAL_ROLES = ['runtime_background', 'video_background_portrait', 'video_background_landscape']
const VISUAL_ROLE_LABELS = { runtime_background: 'App background', video_background_portrait: 'Portrait video background', video_background_landscape: 'Landscape video background', category_selector: 'Category selector', quiz_tile: 'Quiz tile', answer_image: 'Answer image' }

function VisualsWorkspace({ category, providers, onStage, onJob, refreshToken, onCategoryRefresh }) {
  const [payload, setPayload] = useState(null)
  const [selectedId, setSelectedId] = useState('')
  const [checked, setChecked] = useState([])
  const [filters, setFilters] = useState({ role: 'all', status: 'all', q: '' })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [dialog, setDialog] = useState('')

  async function loadVisuals(preferredId) {
    if (!category) return
    setLoading(true); setError('')
    try {
      const result = await api(`/api/studio/categories/${category.slug}/visuals`)
      setPayload(result)
      const ids = result.assets.map((item) => item.asset_id)
      const next = preferredId || (ids.includes(selectedId) ? selectedId : ids[0] || '')
      setSelectedId(next)
      setChecked((current) => current.filter((id) => ids.includes(id)))
    } catch (requestError) { setError(requestError.message); setPayload(null) } finally { setLoading(false) }
  }

  useEffect(() => { loadVisuals() }, [category?.slug, refreshToken])
  useEffect(() => { setChecked([]) }, [category?.slug])
  const assets = payload?.assets || []
  const visible = assets.filter((asset) => {
    const roleMatch = filters.role === 'all' || (filters.role === 'category' ? [...BACKGROUND_VISUAL_ROLES, 'category_selector'].includes(asset.role) : filters.role === 'tiles' ? asset.role === 'quiz_tile' : asset.role === 'answer_image')
    const statusMatch = filters.status === 'all' || asset.status === filters.status
    const text = `${asset.asset_id} ${asset.label || ''} ${asset.visual_summary || ''}`.toLowerCase()
    return roleMatch && statusMatch && text.includes(filters.q.trim().toLowerCase())
  })
  const selected = assets.find((item) => item.asset_id === selectedId)
  const selectedAssets = assets.filter((item) => checked.includes(item.asset_id))
  const blockedReason = payload?.blocked_reason
  function toggle(id) { setChecked((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]) }
  function selectRole(role) { setChecked(assets.filter((item) => item.role === role).map((item) => item.asset_id)) }
  async function uploaded(event) {
    const file = event.target.files?.[0]
    if (!file) return
    setError('')
    try { await upload(`/api/studio/categories/${category.slug}/visuals/background`, file); await loadVisuals(`${category.slug}_runtime_background`); await onCategoryRefresh() } catch (uploadError) { setError(uploadError.message) }
    event.target.value = ''
  }
  const summary = payload?.summary
  return <div className="visual-studio-layout">
    <section className="visual-canvas">
      <StageNavigation active="visuals" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">VISUAL LIBRARY</p><h1>{category.name}</h1></div>
        <div className="question-actions">
          {blockedReason && <span className="toolbar-gate"><CircleAlert size={14} />Prerequisites required</span>}
          <label className={`button secondary upload-button ${blockedReason ? 'disabled' : ''}`}><Upload size={15} />App background<input disabled={Boolean(blockedReason)} type="file" accept="image/*" onChange={uploaded} /></label>
          <button className="button secondary" disabled={Boolean(blockedReason)} onClick={() => setDialog('portrait-video')}><Image size={15} />Portrait video</button>
          <button className="button secondary" disabled={Boolean(blockedReason)} onClick={() => setDialog('landscape')}><Image size={15} />Landscape video</button>
          <button className="button secondary" disabled={Boolean(blockedReason)} onClick={() => setDialog('plan')}><Sparkles size={15} />Plan prompts</button>
          <button className="button primary" disabled={!checked.length} onClick={() => setDialog('generate')}><Image size={15} />Generate {checked.length || ''}</button>
        </div>
      </div>
      {summary && <div className="bank-summary">
        <BankStat value={summary.required_total ?? summary.total} label="Required assets" detail={`${summary.roles.quiz_tile || 0} tiles · ${summary.roles.answer_image || 0} answers`} tone="blue" />
        <BankStat value={summary.required_generated ?? summary.generated} label="Generated" detail={`${(summary.required_total ?? summary.total) - (summary.required_generated ?? summary.generated)} required remaining · ${summary.optional_generated || 0}/${summary.optional_total || 0} optional`} tone="violet" />
        <BankStat value={summary.approved} label="Approved" detail={`${summary.pending_review} awaiting review`} tone="green" />
        <BankStat value={summary.attention} label="Attention" detail={`${summary.unplanned} prompts unplanned`} tone="amber" />
      </div>}
      <div className="visual-filters">
        <div className="bank-search"><Image size={15} /><input placeholder="Search assets or subjects" value={filters.q} onChange={(event) => setFilters({ ...filters, q: event.target.value })} /></div>
        <select value={filters.role} onChange={(event) => setFilters({ ...filters, role: event.target.value })}><option value="all">All visual types</option><option value="category">Category assets</option><option value="tiles">Quiz tiles</option><option value="answers">Answer images</option></select>
        <select value={filters.status} onChange={(event) => setFilters({ ...filters, status: event.target.value })}><option value="all">All statuses</option><option value="pending_generation">Pending generation</option><option value="generated_pending_review">Awaiting review</option><option value="approved">Approved</option><option value="rejected">Rejected</option><option value="generation_failed">Failed</option></select>
        <span>{visible.length} visible</span><button className="icon-button" title="Refresh visuals" onClick={() => loadVisuals()}><RefreshCw size={16} /></button>
      </div>
      <div className="visual-selection-bar">
        <button className="button secondary" disabled={!assets.some((item) => item.role === 'quiz_tile')} onClick={() => selectRole('quiz_tile')}><ListChecks size={14} />Select all tiles</button>
        <button className="button secondary" disabled={!assets.some((item) => item.role === 'answer_image')} onClick={() => selectRole('answer_image')}><ListChecks size={14} />Select all answer images</button>
        <span>{checked.length} selected</span>
        {checked.length > 0 && <button className="button quiet" onClick={() => setChecked([])}><X size={14} />Clear</button>}
      </div>
      <div className="visual-grid-shell">
        <div className="visual-grid">
          {loading && [...Array(12)].map((_, index) => <div className="visual-card-skeleton" key={index} />)}
          {!loading && visible.map((asset) => <button className={`visual-card ${selectedId === asset.asset_id ? 'selected' : ''}`} onClick={() => setSelectedId(asset.asset_id)} key={asset.asset_id}>
            <span className="visual-thumb">{asset.image_url ? <img src={`${asset.image_url}?r=${refreshToken}`} alt="" /> : <Image size={28} />}{!BACKGROUND_VISUAL_ROLES.includes(asset.role) && <input type="checkbox" aria-label={`Select ${asset.asset_id}`} checked={checked.includes(asset.asset_id)} onClick={(event) => event.stopPropagation()} onChange={() => toggle(asset.asset_id)} />}</span>
            <span className="visual-card-copy"><strong>{asset.label || asset.asset_id.replaceAll('_', ' ')}</strong><small>{VISUAL_ROLE_LABELS[asset.role]}</small></span>
            <StatusBadge status={asset.status === 'generated_pending_review' ? 'attention' : asset.status} label={asset.status === 'generated_pending_review' ? 'Awaiting review' : undefined} />
          </button>)}
          {!loading && !visible.length && <EmptyState icon={blockedReason ? CircleDashed : Image} title={blockedReason ? 'Visual stage blocked' : 'No matching visuals'} detail={blockedReason || 'Adjust the filters or create the visual prompt plan.'} />}
        </div>
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    <VisualInspector category={category} asset={selected} providers={providers} onChanged={async () => { await loadVisuals(selectedId); await onCategoryRefresh() }} onJob={onJob} onGenerate={() => { setChecked(selected ? [selected.asset_id] : []); setDialog('generate') }} />
    {dialog === 'plan' && <VisualPromptDialog category={category} providers={providers} current={payload?.prompt_plan} onClose={() => setDialog('')} onQueued={(job) => { setDialog(''); onJob(job) }} />}
    {dialog === 'portrait-video' && <VideoBackgroundDialog layout="portrait" category={category} providers={providers} asset={assets.find((item) => item.role === 'video_background_portrait')} onClose={() => setDialog('')} onQueued={(job) => { setDialog(''); onJob(job) }} />}
    {dialog === 'landscape' && <VideoBackgroundDialog layout="landscape" category={category} providers={providers} asset={assets.find((item) => item.role === 'video_background_landscape')} onClose={() => setDialog('')} onQueued={(job) => { setDialog(''); onJob(job) }} />}
    {dialog === 'generate' && <VisualGenerateDialog category={category} providers={providers} assets={selectedAssets} onClose={() => setDialog('')} onQueued={(job) => { setDialog(''); setChecked([]); onJob(job) }} />}
  </div>
}

function VisualInspector({ category, asset, onChanged, onGenerate }) {
  const [prompt, setPrompt] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => { setPrompt(asset?.prompt || ''); setNotice('') }, [asset])
  if (!asset) return <aside className="visual-inspector"><div className="inspector-title"><div><Image size={16} /><strong>Visual details</strong></div></div><EmptyState icon={Image} title="Select a visual" detail="Preview, prompt, and review controls appear here." /></aside>
  const uploadOnly = BACKGROUND_VISUAL_ROLES.includes(asset.role)
  async function savePrompt() { setBusy(true); setNotice(''); try { await patch(`/api/studio/categories/${category.slug}/visuals/${asset.asset_id}/prompt`, { prompt }); setNotice('Prompt saved'); await onChanged() } catch (error) { setNotice(error.message) } finally { setBusy(false) } }
  async function review(status) { setBusy(true); setNotice(''); try { await post(`/api/studio/categories/${category.slug}/visuals/${asset.asset_id}/review`, { status }); setNotice(status === 'approved' ? 'Visual approved' : 'Visual rejected'); await onChanged() } catch (error) { setNotice(error.message) } finally { setBusy(false) } }
  return <aside className="visual-inspector">
    <div className="inspector-title"><div><Image size={16} /><strong>Visual details</strong></div><StatusBadge status={asset.status === 'generated_pending_review' ? 'attention' : asset.status} label={asset.status === 'generated_pending_review' ? 'Awaiting review' : undefined} /></div>
    <div className="visual-inspector-scroll">
      <div className={`visual-preview ${asset.role}`}>{asset.image_url ? <img src={asset.image_url} alt={asset.label || asset.asset_id} /> : <Image size={38} />}</div>
      <div className="visual-meta"><span className="difficulty-pill">{VISUAL_ROLE_LABELS[asset.role]}</span><code>{asset.asset_id}</code>{asset.generation > 0 && <small>v{asset.generation}</small>}</div>
      {asset.visual_summary && <p className="visual-summary">{asset.visual_summary}</p>}
      {!uploadOnly && <label>{asset.prompt_status === 'unplanned' ? 'Fallback prompt' : 'Planned prompt'}<textarea rows="10" value={prompt} onChange={(event) => setPrompt(event.target.value)} /></label>}
      {!uploadOnly && <div className="visual-edit-actions"><button className="button secondary" disabled={busy || prompt === asset.prompt} onClick={savePrompt}><Save size={14} />Save prompt</button><button className="button primary" disabled={busy} onClick={onGenerate}><RefreshCw size={14} />{asset.image_url ? 'Regenerate' : 'Generate'}</button></div>}
      {asset.error && <div className="inline-error"><CircleAlert size={14} />{asset.error}</div>}
      {asset.image_url && <div className="review-section"><span className="inspector-label">IMAGE REVIEW</span><div className="visual-review-actions"><button className="button approve" disabled={busy} onClick={() => review('approved')}><Check size={15} />Approve</button><button className="button danger" disabled={busy} onClick={() => review('rejected')}><Archive size={14} />Reject</button></div></div>}
      {notice && <div className={notice.includes('approved') || notice.includes('saved') ? 'form-notice success inspector-notice' : 'form-notice inspector-notice'}>{notice}</div>}
    </div>
  </aside>
}

function VideoBackgroundDialog({ layout, category, providers, asset, onClose, onQueued }) {
  const portrait = layout === 'portrait'
  const endpoint = portrait ? 'portrait-video-background' : 'landscape-background'
  const inputPrefix = portrait ? 'portrait-video' : 'landscape'
  const planners = providers.filter((provider) => provider.enabled && provider.provider_type === 'openai_compatible_llm')
  const imageProviders = providers.filter((provider) => provider.enabled && ['openai_images', 'imagestudio'].includes(provider.provider_type))
  const planner = planners[0]
  const imageProvider = imageProviders.find((provider) => provider.provider_type === 'openai_images') || imageProviders[0]
  const [form, setForm] = useState({
    planner_provider_id: planner?.id || '',
    planner_model: planner?.default_model || planner?.discovered_models?.[0] || '',
    image_provider_id: imageProvider?.id || '',
    image_model: imageProvider?.default_model || imageProvider?.discovered_models?.[0] || '',
    quality: 'medium',
    guidance: '',
    seed: 20260805,
    refresh_plan: false,
    force: Boolean(asset?.image_url),
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const selectedPlanner = planners.find((item) => item.id === form.planner_provider_id)
  const selectedImageProvider = imageProviders.find((item) => item.id === form.image_provider_id)
  function choosePlanner(id) { const item = planners.find((candidate) => candidate.id === id); setForm({ ...form, planner_provider_id: id, planner_model: item?.default_model || item?.discovered_models?.[0] || '' }) }
  function chooseImageProvider(id) { const item = imageProviders.find((candidate) => candidate.id === id); setForm({ ...form, image_provider_id: id, image_model: item?.default_model || item?.discovered_models?.[0] || '' }) }
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    try { onQueued(await post(`/api/studio/categories/${category.slug}/visuals/${endpoint}`, { ...form, seed: Number(form.seed) })) } catch (requestError) { setError(requestError.message); setBusy(false) }
  }
  return <div className="dialog-backdrop"><section className="dialog visual-dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">VIDEO BACKGROUND</p><h2>{asset?.image_url ? `Regenerate ${layout} video background` : `Generate ${layout} video background`}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <div className="dialog-grid"><label>Planner connection<select value={form.planner_provider_id} onChange={(event) => choosePlanner(event.target.value)}><option value="" disabled>Select a planner</option>{planners.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label><label>Planner model<input list={`${inputPrefix}-planner-models`} value={form.planner_model} onChange={(event) => setForm({ ...form, planner_model: event.target.value })} /><datalist id={`${inputPrefix}-planner-models`}>{selectedPlanner?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label></div>
    <div className="dialog-grid"><label>Image provider<select value={form.image_provider_id} onChange={(event) => chooseImageProvider(event.target.value)}><option value="" disabled>Select an image provider</option>{imageProviders.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label><label>Image model<input list={`${inputPrefix}-image-models`} value={form.image_model} onChange={(event) => setForm({ ...form, image_model: event.target.value })} /><datalist id={`${inputPrefix}-image-models`}>{selectedImageProvider?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label></div>
    {selectedImageProvider?.provider_type === 'openai_images' && <label>Quality<select value={form.quality} onChange={(event) => setForm({ ...form, quality: event.target.value })}><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option><option value="auto">Auto</option></select></label>}
    <label>Additional direction<textarea rows="4" placeholder="Optional category-specific art direction" value={form.guidance} onChange={(event) => setForm({ ...form, guidance: event.target.value })} /></label>
    <div className="dialog-grid"><label>Seed<input type="number" min="0" max="2147483647" value={form.seed} onChange={(event) => setForm({ ...form, seed: event.target.value })} /></label><div className="dialog-checks"><label className="check-field"><input type="checkbox" checked={form.refresh_plan} onChange={(event) => setForm({ ...form, refresh_plan: event.target.checked })} />Create a new prompt plan</label><label className="check-field"><input type="checkbox" checked={form.force} onChange={(event) => setForm({ ...form, force: event.target.checked })} />Render a new image</label></div></div>
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !form.planner_model || !form.image_model}>{busy ? <LoaderCircle className="spin" size={15} /> : <Image size={15} />}Start generation</button></div>
  </form></section></div>
}

function VisualPromptDialog({ category, providers, current, onClose, onQueued }) {
  const llms = providers.filter((provider) => provider.provider_type === 'openai_compatible_llm' && provider.enabled)
  const provider = llms[0]
  const [form, setForm] = useState({ provider_id: provider?.id || '', model: provider?.default_model || provider?.discovered_models?.[0] || '', roles: { selector: true, tiles: true, answers: true }, guidance: current?.guidance || category.editorial_brief || '', seed: current?.seed || 20260805, force: false })
  const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  const selectedProvider = llms.find((item) => item.id === form.provider_id)
  function chooseProvider(id) { const item = llms.find((candidate) => candidate.id === id); setForm({ ...form, provider_id: id, model: item?.default_model || item?.discovered_models?.[0] || '' }) }
  async function submit(event) { event.preventDefault(); setBusy(true); setError(''); try { const roles = Object.entries(form.roles).filter(([, enabled]) => enabled).map(([role]) => role); onQueued(await post(`/api/studio/categories/${category.slug}/visuals/plan`, { ...form, roles, seed: Number(form.seed) })) } catch (requestError) { setError(requestError.message); setBusy(false) } }
  const roleCount = Object.values(form.roles).filter(Boolean).length
  return <div className="dialog-backdrop"><section className="dialog visual-dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">VISUAL LIBRARY</p><h2>Plan generation prompts</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <label>LLM connection<select value={form.provider_id} onChange={(event) => chooseProvider(event.target.value)}><option value="" disabled>Select a provider</option>{llms.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
    <label>Model<input list="visual-prompt-models" value={form.model} onChange={(event) => setForm({ ...form, model: event.target.value })} /><datalist id="visual-prompt-models">{selectedProvider?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label>
    <fieldset className="role-options"><legend>Prompt groups</legend>{Object.entries({ selector: 'Category selector', tiles: 'Quiz tiles', answers: 'Answer images' }).map(([role, label]) => <label key={role}><input type="checkbox" checked={form.roles[role]} onChange={(event) => setForm({ ...form, roles: { ...form.roles, [role]: event.target.checked } })} />{label}</label>)}</fieldset>
    <label>Category guidance<textarea rows="4" value={form.guidance} onChange={(event) => setForm({ ...form, guidance: event.target.value })} /></label>
    <div className="dialog-grid"><label>Seed<input type="number" min="0" max="2147483647" value={form.seed} onChange={(event) => setForm({ ...form, seed: event.target.value })} /></label><label className="check-field"><input type="checkbox" checked={form.force} onChange={(event) => setForm({ ...form, force: event.target.checked })} />Replace existing prompts</label></div>
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}<div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !llms.length || !form.model || !roleCount}>{busy ? <LoaderCircle className="spin" size={15} /> : <Sparkles size={15} />}Start planning</button></div>
  </form></section></div>
}

function VisualGenerateDialog({ category, providers, assets, onClose, onQueued }) {
  const candidates = providers.filter((provider) => provider.enabled && ['openai_images', 'imagestudio'].includes(provider.provider_type))
  const provider = candidates[0]
  const [form, setForm] = useState({ provider_id: provider?.id || '', model: provider?.default_model || provider?.discovered_models?.[0] || '', quality: 'medium', force: assets.some((asset) => Boolean(asset.image_url)) })
  const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  const selectedProvider = candidates.find((item) => item.id === form.provider_id)
  function chooseProvider(id) { const item = candidates.find((candidate) => candidate.id === id); setForm({ ...form, provider_id: id, model: item?.default_model || item?.discovered_models?.[0] || '' }) }
  async function submit(event) { event.preventDefault(); setBusy(true); setError(''); try { onQueued(await post(`/api/studio/categories/${category.slug}/visuals/generate`, { ...form, asset_ids: assets.map((asset) => asset.asset_id) })) } catch (requestError) { setError(requestError.message); setBusy(false) } }
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">VISUAL LIBRARY</p><h2>Generate {assets.length} visual{assets.length === 1 ? '' : 's'}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <label>Image provider<select value={form.provider_id} onChange={(event) => chooseProvider(event.target.value)}><option value="" disabled>Select a provider</option>{candidates.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
    <label>Model<input list="visual-generation-models" value={form.model} onChange={(event) => setForm({ ...form, model: event.target.value })} /><datalist id="visual-generation-models">{selectedProvider?.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label>
    {selectedProvider?.provider_type === 'openai_images' && <label>Quality<select value={form.quality} onChange={(event) => setForm({ ...form, quality: event.target.value })}><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option><option value="auto">Auto</option></select></label>}
    <label className="check-field"><input type="checkbox" checked={form.force} onChange={(event) => setForm({ ...form, force: event.target.checked })} />Create a new version when cached</label>
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !candidates.length || !form.model}>{busy ? <LoaderCircle className="spin" size={15} /> : <Image size={15} />}Start generation</button></div>
  </form></section></div>
}

const AUDIO_STATUS_LABELS = {
  passed: 'Audited',
  missing: 'Missing',
  failed: 'Failed audit',
  stale: 'Content changed',
  unaudited: 'Needs audit',
  partial: 'Partial',
}

function AudioStatusBadge({ status, label }) {
  const tone = status === 'passed' ? 'ready' : ['failed'].includes(status) ? 'failed' : ['stale', 'unaudited', 'partial'].includes(status) ? 'attention' : 'blocked'
  return <StatusBadge status={tone} label={label || AUDIO_STATUS_LABELS[status] || status} />
}

function AudioWorkspace({ category, providers, onStage, onJob, refreshToken, onCategoryRefresh }) {
  const [payload, setPayload] = useState(null)
  const [selectedId, setSelectedId] = useState('')
  const [checked, setChecked] = useState([])
  const [filters, setFilters] = useState({ difficulty: 'all', status: 'all', q: '' })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [generation, setGeneration] = useState(null)

  async function loadAudio(preferredId) {
    if (!category) return
    setLoading(true); setError('')
    try {
      const result = await api(`/api/studio/categories/${category.slug}/audio`)
      setPayload(result)
      const questionIds = result.questions.map((item) => item.question_id)
      setSelectedId(preferredId || (questionIds.includes(selectedId) ? selectedId : questionIds[0] || ''))
      const clipIds = new Set(result.questions.flatMap((item) => [item.question_audio.clip_id, item.explanation_audio.clip_id]))
      setChecked((current) => current.filter((id) => clipIds.has(id)))
    } catch (requestError) { setError(requestError.message); setPayload(null) } finally { setLoading(false) }
  }

  useEffect(() => { loadAudio() }, [category?.slug, refreshToken])
  useEffect(() => { setChecked([]) }, [category?.slug])
  const questions = payload?.questions || []
  const clips = questions.flatMap((item) => [item.question_audio, item.explanation_audio])
  const missingIds = clips.filter((clip) => clip.status === 'missing').map((clip) => clip.clip_id)
  const attentionIds = clips.filter((clip) => ['failed', 'stale', 'unaudited'].includes(clip.status)).map((clip) => clip.clip_id)
  const visible = questions.filter((item) => {
    const difficultyMatch = filters.difficulty === 'all' || item.difficulty === filters.difficulty
    const statusMatch = filters.status === 'all' || (filters.status === 'attention' ? ['failed', 'stale', 'unaudited', 'partial'].includes(item.status) : item.status === filters.status)
    const text = `${item.question_id} ${item.question} ${item.explanation} ${item.sets.map((set) => set.set_id).join(' ')}`.toLowerCase()
    return difficultyMatch && statusMatch && text.includes(filters.q.trim().toLowerCase())
  })
  const selected = questions.find((item) => item.question_id === selectedId)
  const summary = payload?.summary
  const blockedReason = payload?.blocked_reason
  function toggle(clipId) { setChecked((current) => current.includes(clipId) ? current.filter((item) => item !== clipId) : [...current, clipId]) }
  function openGeneration(clipIds, force = false) { if (clipIds.length) setGeneration({ clipIds, force }) }
  return <div className="audio-studio-layout">
    <section className="audio-canvas">
      <StageNavigation active="audio" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">NARRATION LIBRARY</p><h1>{category.name}</h1></div>
        <div className="question-actions">
          {blockedReason && <span className="toolbar-gate"><CircleAlert size={14} />Prerequisites required</span>}
          <button className="button secondary" disabled={!attentionIds.length} onClick={() => openGeneration(attentionIds)}><RotateCcw size={15} />Retry attention</button>
          <button className="button secondary" disabled={!missingIds.length} onClick={() => openGeneration(missingIds)}><ListChecks size={15} />Generate missing</button>
          <button className="button primary" disabled={!checked.length} onClick={() => openGeneration(checked, true)}><AudioLines size={15} />Generate {checked.length || ''}</button>
        </div>
      </div>
      {summary && <div className="bank-summary">
        <BankStat value={summary.questions} label="Quiz questions" detail={`${summary.clips_total} narration clips`} tone="blue" />
        <BankStat value={summary.generated} label="Generated" detail={`${summary.missing} missing`} tone="violet" />
        <BankStat value={summary.passed} label="Whisper audited" detail={`${summary.clips_total ? Math.round(summary.passed / summary.clips_total * 100) : 0}% accepted`} tone="green" />
        <BankStat value={summary.attention} label="Attention" detail={`${summary.failed} failed · ${summary.unaudited} unaudited`} tone="amber" />
      </div>}
      <div className="audio-filters">
        <div className="bank-search"><Headphones size={15} /><input placeholder="Search narration, IDs, or sets" value={filters.q} onChange={(event) => setFilters({ ...filters, q: event.target.value })} /></div>
        <select value={filters.difficulty} onChange={(event) => setFilters({ ...filters, difficulty: event.target.value })}><option value="all">All difficulties</option><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option></select>
        <select value={filters.status} onChange={(event) => setFilters({ ...filters, status: event.target.value })}><option value="all">All statuses</option><option value="passed">Audited</option><option value="missing">Missing</option><option value="attention">Needs attention</option><option value="failed">Failed audit</option><option value="unaudited">Needs audit</option><option value="stale">Content changed</option></select>
        <span>{visible.length} visible</span><button className="icon-button" title="Refresh audio" onClick={() => loadAudio()}><RefreshCw size={16} /></button>
      </div>
      <div className="audio-selection-bar">
        <button className="button secondary" disabled={!missingIds.length} onClick={() => setChecked(missingIds)}><ListChecks size={14} />Select missing</button>
        <button className="button secondary" disabled={!attentionIds.length} onClick={() => setChecked(attentionIds)}><CircleAlert size={14} />Select attention</button>
        <span>{checked.length} clips selected</span>
        {checked.length > 0 && <button className="button quiet" onClick={() => setChecked([])}><X size={14} />Clear</button>}
      </div>
      <div className="audio-table-shell">
        <div className="audio-table-head"><span>Question</span><span>Question narration</span><span>Explanation</span><span>Status</span></div>
        <div className="audio-table-body">
          {loading && [...Array(8)].map((_, index) => <div className="audio-row-skeleton" key={index} />)}
          {!loading && visible.map((item) => <div role="button" tabIndex="0" className={`audio-row ${selectedId === item.question_id ? 'selected' : ''}`} onClick={() => setSelectedId(item.question_id)} onKeyDown={(event) => event.key === 'Enter' && setSelectedId(item.question_id)} key={item.question_id}>
            <span className="audio-question-copy"><strong>{item.question}</strong><small><code>{item.question_id}</code><span className={`difficulty-pill ${item.difficulty}`}>{item.difficulty}</span>{item.sets.length} set{item.sets.length === 1 ? '' : 's'}</small></span>
            {[item.question_audio, item.explanation_audio].map((clip) => <span className="audio-cell" key={clip.kind} onClick={(event) => event.stopPropagation()}>
              <span><input type="checkbox" aria-label={`Select ${clip.clip_id}`} checked={checked.includes(clip.clip_id)} onChange={() => toggle(clip.clip_id)} /><AudioStatusBadge status={clip.status} /></span>
              {clip.audio_url ? <audio controls preload="none" src={`${clip.audio_url}?r=${refreshToken}`} /> : <small>No audio</small>}
            </span>)}
            <AudioStatusBadge status={item.status} />
          </div>)}
          {!loading && !visible.length && <EmptyState icon={blockedReason ? CircleDashed : Headphones} title={blockedReason ? 'Audio stage blocked' : 'No matching narration'} detail={blockedReason || 'Adjust the filters or generate audio for this category.'} />}
        </div>
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    <AudioInspector category={category} question={selected} onGenerate={(clipId) => openGeneration([clipId], true)} onChanged={async () => { await loadAudio(selectedId); await onCategoryRefresh() }} />
    {generation && <AudioGenerateDialog category={category} providers={providers} clipIds={generation.clipIds} defaultForce={generation.force} onClose={() => setGeneration(null)} onQueued={(job) => { setGeneration(null); setChecked([]); onJob(job) }} />}
  </div>
}

function AudioInspector({ category, question, onGenerate, onChanged }) {
  if (!question) return <aside className="audio-inspector"><div className="inspector-title"><div><Headphones size={16} /><strong>Audio details</strong></div></div><EmptyState icon={Headphones} title="Select a question" detail="Narration and audit results appear here." /></aside>
  return <aside className="audio-inspector">
    <div className="inspector-title"><div><Headphones size={16} /><strong>Audio details</strong></div><AudioStatusBadge status={question.status} /></div>
    <div className="audio-inspector-scroll">
      <div className="audio-inspector-meta"><span className={`difficulty-pill ${question.difficulty}`}>{question.difficulty}</span><code>{question.question_id}</code></div>
      <AudioClipPanel category={category} title="Question narration" text={question.question} clip={question.question_audio} onGenerate={onGenerate} onChanged={onChanged} />
      <AudioClipPanel category={category} title="Answer explanation" text={question.explanation} clip={question.explanation_audio} onGenerate={onGenerate} onChanged={onChanged} />
      <div className="inspector-block"><span className="inspector-label">QUIZ SETS</span><div className="audio-set-list">{question.sets.map((set) => <span key={`${set.set_id}-${set.position}`}><code>{set.set_id}</code><small>Q{set.position}</small></span>)}</div></div>
    </div>
  </aside>
}

function AudioClipPanel({ category, title, text, clip, onGenerate, onChanged }) {
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const audit = clip.audit
  const manuallyAccepted = audit?.manual_review?.status === 'accepted'
  const percent = (value) => Number.isFinite(Number(value)) ? `${Math.round(Number(value) * 100)}%` : '-'
  async function review(decision) {
    setBusy(true); setNotice('')
    try {
      await post(`/api/studio/categories/${category.slug}/audio/review`, { clip_id: clip.clip_id, decision })
      setNotice(decision === 'accept' ? 'Attention cleared for this clip' : 'Whisper result restored')
      await onChanged()
    } catch (error) { setNotice(error.message) } finally { setBusy(false) }
  }
  return <section className="audio-clip-panel">
    <header><div><span>{title}</span><AudioStatusBadge status={clip.status} label={manuallyAccepted ? 'Manually accepted' : undefined} /></div><button className="icon-button quiet" title={`Regenerate ${title.toLowerCase()}`} onClick={() => onGenerate(clip.clip_id)}><RotateCcw size={15} /></button></header>
    <p>{text}</p>
    {clip.audio_url && <audio controls preload="none" src={clip.audio_url} />}
    {audit && <div className="audit-metrics"><span><strong>{percent(audit.score)}</strong><small>Match</small></span><span><strong>{percent(audit.coverage)}</strong><small>Coverage</small></span><span><strong>{percent(audit.wer)}</strong><small>WER</small></span><span><strong>{audit.render_attempt || '-'}</strong><small>Attempt</small></span></div>}
    {audit?.reasons?.length > 0 && <div className={`audit-reasons ${manuallyAccepted ? 'reviewed' : ''}`}>{audit.reasons.map((reason) => <span key={reason}><CircleAlert size={12} />{manuallyAccepted ? 'Whisper flagged: ' : ''}{reason.replaceAll('_', ' ')}</span>)}</div>}
    {audit?.transcript_text && <details className="audit-transcript"><summary>Whisper transcript</summary><p>{audit.transcript_text}</p></details>}
    {clip.status === 'failed' && <div className="audio-review-control"><p>After listening, clear attention only when this exact clip is acceptable.</p><button className="button approve" disabled={busy} onClick={() => review('accept')}><Check size={14} />Clear attention</button></div>}
    {manuallyAccepted && <div className="audio-review-control accepted"><p>Accepted by a reviewer. Whisper metrics and transcript are retained.</p><button className="button secondary" disabled={busy} onClick={() => review('reset')}><RotateCcw size={14} />Restore audit result</button></div>}
    {notice && <div className={notice.includes('cleared') || notice.includes('restored') ? 'form-notice success inspector-notice' : 'form-notice inspector-notice'}>{notice}</div>}
  </section>
}

function AudioGenerateDialog({ category, providers, clipIds, defaultForce, onClose, onQueued }) {
  const narrators = providers.filter((provider) => provider.provider_type === 'vibevoice' && provider.enabled)
  const provider = narrators.find((item) => item.health_status === 'healthy') || narrators[0]
  const [form, setForm] = useState({ provider_id: provider?.id || '', audit_repairs: 2, force: defaultForce })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const selectedProvider = narrators.find((item) => item.id === form.provider_id)
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    try { onQueued(await post(`/api/studio/categories/${category.slug}/audio/generate`, { ...form, audit_repairs: Number(form.audit_repairs), clip_ids: clipIds })) } catch (requestError) { setError(requestError.message); setBusy(false) }
  }
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">NARRATION LIBRARY</p><h2>Generate {clipIds.length} clip{clipIds.length === 1 ? '' : 's'}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <label>Narrator connection<select value={form.provider_id} onChange={(event) => setForm({ ...form, provider_id: event.target.value })}><option value="" disabled>Select a provider</option>{narrators.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
    <div className="dialog-grid"><label>Audit repair attempts<input type="number" min="0" max="4" value={form.audit_repairs} onChange={(event) => setForm({ ...form, audit_repairs: event.target.value })} /></label><label className="check-field"><input type="checkbox" checked={form.force} onChange={(event) => setForm({ ...form, force: event.target.checked })} />Replace existing clips</label></div>
    {selectedProvider && <div className={`provider-choice-health ${selectedProvider.health_status}`}><Wifi size={14} /><span><strong>{selectedProvider.health_status}</strong><small>{selectedProvider.health_message || selectedProvider.base_url}</small></span></div>}
    {!narrators.length && <div className="inline-error"><CircleAlert size={15} />Configure a VibeVoice connection in Admin first.</div>}
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !narrators.length}>{busy ? <LoaderCircle className="spin" size={15} /> : <AudioLines size={15} />}Start generation</button></div>
  </form></section></div>
}

function formatBytes(value) {
  const bytes = Number(value || 0)
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function PublishWorkspace({ category, onStage, onJob, refreshToken, onCategoryRefresh }) {
  const [payload, setPayload] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [dialog, setDialog] = useState(null)

  async function loadPublish() {
    if (!category) return
    setLoading(true); setError('')
    try { setPayload(await api(`/api/studio/categories/${category.slug}/publish`)) } catch (requestError) { setError(requestError.message); setPayload(null) } finally { setLoading(false) }
  }

  useEffect(() => { loadPublish() }, [category?.slug, refreshToken])
  const summary = payload?.summary
  const current = payload?.current
  return <div className="publish-studio-layout">
    <section className="publish-canvas">
      <StageNavigation active="publish" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">RELEASE MANAGEMENT</p><h1>{category.name}</h1></div>
        <div className="question-actions"><button className="button secondary" onClick={loadPublish}><RefreshCw size={15} />Verify</button><button className="button primary" disabled={!payload?.can_publish} onClick={() => setDialog({ type: 'publish' })}><PackageCheck size={15} />{payload?.redeploy_required ? 'Redeploy category' : 'Publish category'}</button></div>
      </div>
      {summary && <div className="bank-summary">
        <BankStat value={summary.quiz_sets} label="Quiz sets" detail={`${summary.questions} questions`} tone="blue" />
        <BankStat value={summary.visual_assets} label="Visual assets" detail="Category and answers" tone="violet" />
        <BankStat value={summary.audited_clips} label="Audited clips" detail={`${summary.questions * 2} required`} tone="green" />
        <BankStat value={summary.release_count} label="Releases" detail={current ? `v${current.bundle_version} active` : 'None active'} tone="amber" />
      </div>}
      <div className="publish-scroll">
        {loading && [...Array(5)].map((_, index) => <div className="publish-skeleton" key={index} />)}
        {!loading && payload && <>
          <section className="publish-readiness">
            <div className="section-heading"><div><p className="kicker">RELEASE GATES</p><h2>Production readiness</h2></div><StatusBadge status={payload.ready ? 'ready' : 'attention'} label={payload.ready ? 'Ready to publish' : 'Blocked'} /></div>
            <div className="readiness-table">{payload.gates.map((gate) => {
              const ratio = gate.target ? Math.min(100, Math.round(gate.current / gate.target * 100)) : 0
              return <div className="readiness-row" key={gate.id}><StatusIcon status={gate.status} /><div className="readiness-name"><strong>{gate.label}</strong><small>{gate.detail}</small></div><div className="readiness-progress"><span><i style={{ width: `${ratio}%` }} /></span><small>{ratio}%</small></div><div className="readiness-count"><strong>{gate.current}</strong><span>/ {gate.target}</span></div><StatusBadge status={gate.status} /></div>
            })}</div>
            {payload.active_jobs.length > 0 && <div className="publish-blocker"><LoaderCircle className="spin" size={15} /><span><strong>Production job active</strong><small>{payload.active_jobs.map((job) => job.kind.replaceAll('_', ' ')).join(', ')}</small></span></div>}
            {payload.warnings.length > 0 && <div className="publish-warnings">{payload.warnings.map((warning) => <span key={warning}><CircleAlert size={13} />{warning}</span>)}</div>}
          </section>
          <section className="release-history-section">
            <div className="section-heading"><div><p className="kicker">IMMUTABLE HISTORY</p><h2>Category releases</h2></div><span>{payload.versions.length} version{payload.versions.length === 1 ? '' : 's'}</span></div>
            {payload.versions.length ? <div className="release-table"><div className="release-table-head"><span>Version</span><span>Contents</span><span>Archive</span><span>Published</span><span /></div>{payload.versions.map((release) => <div className={`release-row ${release.is_current ? 'current' : ''}`} key={release.bundle_version}><span className="release-version"><strong>v{release.bundle_version}</strong>{release.is_current && <StatusBadge status="published" label="Active" />}</span><span><strong>{release.quiz_count} quizzes</strong><small>{release.question_count} questions</small></span><span><strong>{formatBytes(release.archive_bytes)}</strong><small><code>{release.archive_sha256?.slice(0, 12)}</code></small></span><span><strong>{new Date(release.generated_at_utc).toLocaleDateString()}</strong><small>{new Date(release.generated_at_utc).toLocaleTimeString()}</small></span><span className="release-actions"><a className="icon-button" title={`Download version ${release.bundle_version}`} href={release.download_url}><Download size={15} /></a>{!release.is_current && <button className="icon-button" title={`Activate version ${release.bundle_version}`} onClick={() => setDialog({ type: 'activate', release })}><History size={15} /></button>}</span></div>)}</div> : <EmptyState icon={PackageCheck} title="No releases yet" detail="Complete every release gate before publishing this category." />}
          </section>
        </>}
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    <ReleaseInspector category={category} current={current} ready={payload?.ready} />
    {dialog?.type === 'publish' && <PublishDialog category={category} payload={payload} onClose={() => setDialog(null)} onQueued={(job) => { setDialog(null); onJob(job) }} />}
    {dialog?.type === 'activate' && <ActivateReleaseDialog category={category} release={dialog.release} onClose={() => setDialog(null)} onActivated={async () => { setDialog(null); await loadPublish(); await onCategoryRefresh() }} />}
  </div>
}

function ReleaseInspector({ category, current, ready }) {
  return <aside className="release-inspector">
    <div className="inspector-title"><div><PackageCheck size={16} /><strong>Active release</strong></div>{current && <StatusBadge status="published" label={`v${current.bundle_version}`} />}</div>
    <div className="release-inspector-scroll">
      {current ? <>
        <div className="release-hero"><span>VERSION</span><strong>v{current.bundle_version}</strong><small>{new Date(current.generated_at_utc).toLocaleString()}</small></div>
        <div className="inspector-block"><span className="inspector-label">CONTENTS</span><dl className="compact-list"><div><dt>Quiz sets</dt><dd>{current.quiz_count}</dd></div><div><dt>Questions</dt><dd>{current.question_count}</dd></div><div><dt>Archive</dt><dd>{formatBytes(current.archive_bytes)}</dd></div><div><dt>Renderer</dt><dd>v{current.minimum_renderer_version}+</dd></div></dl></div>
        <div className="inspector-block"><span className="inspector-label">CONTENT HASH</span><code className="release-hash">{current.content_hash}</code></div>
        <div className="inspector-block"><span className="inspector-label">ARCHIVE SHA-256</span><code className="release-hash">{current.archive_sha256}</code></div>
        <a className="button secondary full" href={current.download_url}><Download size={15} />Download active ZIP</a>
      </> : <EmptyState icon={PackageCheck} title="No active release" detail={`${category.name} has not been published.`} />}
      <div className={`release-state ${ready ? 'ready' : 'blocked'}`}><StatusIcon status={ready ? 'ready' : 'blocked'} /><span><strong>{ready ? 'Release inputs ready' : 'Release inputs blocked'}</strong><small>{ready ? 'All required artifacts verified' : 'Review the production gates'}</small></span></div>
    </div>
  </aside>
}

function PublishDialog({ category, payload, onClose, onQueued }) {
  const [force, setForce] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function submit(event) { event.preventDefault(); setBusy(true); setError(''); try { onQueued(await post(`/api/studio/categories/${category.slug}/publish`, { force_new_version: force })) } catch (requestError) { setError(requestError.message); setBusy(false) } }
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">CATEGORY RELEASE</p><h2>Publish {category.name}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <div className="publish-dialog-summary"><span><strong>{payload.summary.quiz_sets}</strong><small>Quiz sets</small></span><span><strong>{payload.summary.questions}</strong><small>Questions</small></span><span><strong>{payload.summary.audited_clips}</strong><small>Audited clips</small></span></div>
    <label className="check-field"><input type="checkbox" checked={force} onChange={(event) => setForce(event.target.checked)} />Create a new version when content is unchanged</label>
    {payload.warnings.map((warning) => <div className="inline-warning" key={warning}><CircleAlert size={14} />{warning}</div>)}
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy}>{busy ? <LoaderCircle className="spin" size={15} /> : <PackageCheck size={15} />}Publish</button></div>
  </form></section></div>
}

function ActivateReleaseDialog({ category, release, onClose, onActivated }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function activate() { setBusy(true); setError(''); try { await post(`/api/studio/categories/${category.slug}/publish/activate`, { version: release.bundle_version }); await onActivated() } catch (requestError) { setError(requestError.message); setBusy(false) } }
  return <div className="dialog-backdrop"><section className="dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">RELEASE HISTORY</p><h2>Activate version {release.bundle_version}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><div className="activation-dialog"><div className="publish-dialog-summary"><span><strong>{release.quiz_count}</strong><small>Quiz sets</small></span><span><strong>{release.question_count}</strong><small>Questions</small></span><span><strong>{formatBytes(release.archive_bytes)}</strong><small>Archive</small></span></div><code>{release.content_hash}</code>{error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}<div className="dialog-actions"><button className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy} onClick={activate}>{busy ? <LoaderCircle className="spin" size={15} /> : <History size={15} />}Activate version</button></div></div></section></div>
}

function formatDuration(value) {
  const seconds = Math.max(0, Math.round(Number(value || 0)))
  if (!seconds) return '-'
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`
}

function VideoWorkspace({ category, onStage, onJob, refreshToken }) {
  const [payload, setPayload] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [orientation, setOrientation] = useState('all')
  const [dialog, setDialog] = useState(null)

  async function loadVideos() {
    if (!category) return
    setLoading(true)
    setError('')
    try {
      setPayload(await api(`/api/studio/categories/${category.slug}/videos`))
    } catch (requestError) {
      setError(requestError.message)
      setPayload(null)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { loadVideos() }, [category?.slug, refreshToken])
  const allVideos = payload?.videos || []
  const videos = allVideos.filter((item) => orientation === 'all' || item.orientation === orientation)
  const completed = allVideos.filter((item) => item.status === 'complete')
  const rendering = allVideos.filter((item) => ['queued', 'rendering'].includes(item.status))
  const totalMinutes = Math.round(completed.reduce((sum, item) => sum + Number(item.duration_seconds || 0), 0) / 60)

  return <div className="video-studio-layout">
    <section className="video-canvas">
      <StageNavigation active="video" onStage={onStage} />
      <div className="question-toolbar">
        <div><p className="kicker">VIDEO LIBRARY</p><h1>{category.name}</h1></div>
        <div className="question-actions">
          <button className="button secondary" onClick={loadVideos}><RefreshCw size={15} />Refresh</button>
          <button className="button primary" disabled={!payload?.can_create} onClick={() => setDialog({ type: 'create' })}><Film size={15} />Create video</button>
        </div>
      </div>
      <div className="bank-summary">
        <BankStat value={allVideos.length} label="Video records" detail="All render attempts" tone="blue" />
        <BankStat value={completed.length} label="Ready" detail="Playable and downloadable" tone="green" />
        <BankStat value={rendering.length} label="Rendering" detail="Queued or active" tone="amber" />
        <BankStat value={totalMinutes} label="Runtime" detail="Completed minutes" tone="violet" />
      </div>
      <div className="video-scroll">
        <div className="video-index-heading">
          <div><p className="kicker">RENDER HISTORY</p><h2>Created videos</h2></div>
          <div className="segmented-control compact">{['all', 'landscape', 'portrait'].map((value) => <button className={orientation === value ? 'active' : ''} key={value} onClick={() => setOrientation(value)}>{value}</button>)}</div>
        </div>
        {payload?.blocked_reason && <div className="video-blocked"><CircleAlert size={16} /><span>{payload.blocked_reason}</span></div>}
        {loading && [...Array(5)].map((_, index) => <div className="publish-skeleton" key={index} />)}
        {!loading && videos.length > 0 && <div className="video-table-shell">
          <div className="video-table-head"><span>Video</span><span>Source sets</span><span>Runtime</span><span>Created</span><span>Status</span><span /></div>
          {videos.map((video) => <button className="video-row" key={video.id} onClick={() => setDialog({ type: 'preview', video })}>
            <span className="video-primary"><span className={`video-format ${video.orientation}`}>{video.orientation === 'landscape' ? <Monitor size={18} /> : <Smartphone size={18} />}</span><span className="video-name"><strong>{video.title}</strong><small>{video.orientation} · {video.question_count} questions · bundle v{video.bundle_version}</small></span></span>
            <span><strong>{video.selections.map((item) => item.title || `Set ${item.number}`).join(', ')}</strong><small>{video.selections.length} set{video.selections.length === 1 ? '' : 's'}</small></span>
            <span><strong>{formatDuration(video.duration_seconds)}</strong><small>{video.file_bytes ? formatBytes(video.file_bytes) : 'Pending'}</small></span>
            <span><strong>{new Date(video.created_at).toLocaleDateString()}</strong><small>{new Date(video.created_at).toLocaleTimeString()}</small></span>
            <span><StatusBadge status={video.status} /></span>
            <span className="video-row-action">{video.status === 'complete' ? <Play size={15} /> : <ArrowRight size={15} />}</span>
          </button>)}
        </div>}
        {!loading && !videos.length && <EmptyState icon={Film} title="No videos in this view" detail="Create a video from one or more published quiz sets." />}
      </div>
      {error && <div className="bank-error"><CircleAlert size={15} />{error}<button title="Dismiss" onClick={() => setError('')}><X size={15} /></button></div>}
    </section>
    {dialog?.type === 'create' && <VideoCreateDialog category={category} payload={payload} onClose={() => setDialog(null)} onQueued={async (job) => { setDialog(null); onJob(job); await loadVideos() }} />}
    {dialog?.type === 'preview' && <VideoPreviewDialog video={dialog.video} onClose={() => setDialog(null)} />}
  </div>
}

function VideoCreateDialog({ category, payload, onClose, onQueued }) {
  const firstAvailable = payload.backgrounds?.landscape ? 'landscape' : 'portrait'
  const [orientation, setOrientation] = useState(firstAvailable)
  const [selected, setSelected] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const maximum = payload.limits?.[orientation] || (orientation === 'landscape' ? 50 : 10)
  const setMap = new Map(payload.sets.map((item) => [item.set_id, item]))
  const questionCount = selected.reduce((sum, id) => sum + Number(setMap.get(id)?.question_count || 0), 0)

  function chooseOrientation(value) {
    setOrientation(value)
    setSelected((current) => value === 'portrait' ? current.slice(0, 1) : current)
  }

  function toggleSet(item) {
    setSelected((current) => {
      if (current.includes(item.set_id)) return current.filter((id) => id !== item.set_id)
      const currentCount = current.reduce((sum, id) => sum + Number(setMap.get(id)?.question_count || 0), 0)
      if (currentCount + item.question_count > maximum) return current
      return [...current, item.set_id]
    })
  }

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      await onQueued(await post(`/api/studio/categories/${category.slug}/videos`, { orientation, set_ids: selected }))
    } catch (requestError) {
      setError(requestError.message)
      setBusy(false)
    }
  }

  return <div className="dialog-backdrop"><section className="dialog video-create-dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">NEW RENDER</p><h2>Create {category.name} video</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><form onSubmit={submit}>
    <div className="video-orientation-options">
      <button type="button" className={orientation === 'landscape' ? 'active' : ''} disabled={!payload.backgrounds?.landscape} onClick={() => chooseOrientation('landscape')}><Monitor size={20} /><span><strong>Landscape</strong><small>Up to 50 questions</small></span>{orientation === 'landscape' && <Check size={16} />}</button>
      <button type="button" className={orientation === 'portrait' ? 'active' : ''} disabled={!payload.backgrounds?.portrait} onClick={() => chooseOrientation('portrait')}><Smartphone size={20} /><span><strong>Portrait</strong><small>Up to 10 questions</small></span>{orientation === 'portrait' && <Check size={16} />}</button>
    </div>
    <div className="video-selection-summary"><span><strong>{selected.length}</strong><small>Sets</small></span><span><strong>{questionCount}</strong><small>Questions</small></span><span><strong>{maximum - questionCount}</strong><small>Available</small></span></div>
    <div className="video-set-list">{['beginner', 'intermediate'].map((difficulty) => <div className="video-set-group" key={difficulty}><div><span className={`difficulty-mark ${difficulty}`}>{difficulty === 'beginner' ? 'B' : 'I'}</span><strong>{difficulty}</strong></div>{payload.sets.filter((item) => item.difficulty === difficulty).map((item) => { const checked = selected.includes(item.set_id); const disabled = !checked && questionCount + item.question_count > maximum; return <button type="button" className={checked ? 'selected' : ''} disabled={disabled} key={item.set_id} onClick={() => toggleSet(item)}><span className="video-checkbox">{checked && <Check size={13} />}</span><span><strong>{item.title}</strong><small>Set {item.number} · {item.question_count} questions</small></span></button> })}</div>)}</div>
    {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
    <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy || !selected.length}>{busy ? <LoaderCircle className="spin" size={15} /> : <Film size={15} />}Start render</button></div>
  </form></section></div>
}

function VideoPreviewDialog({ video, onClose }) {
  const ready = video.status === 'complete' && video.stream_url
  return <div className="dialog-backdrop"><section className="dialog video-preview-dialog" role="dialog" aria-modal="true"><header><div><p className="kicker">VIDEO DETAILS</p><h2>{video.title}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header><div className="video-preview-body">
    {ready ? <video controls preload="metadata" src={video.stream_url}>Your browser cannot play this video.</video> : <div className="video-preview-pending">{['queued', 'rendering'].includes(video.status) ? <LoaderCircle className="spin" size={30} /> : <CircleAlert size={30} />}<strong>{video.status === 'interrupted' ? 'Render interrupted' : video.status === 'failed' ? 'Render failed' : 'Render in progress'}</strong><span>{video.error || 'Progress is available in the jobs drawer.'}</span></div>}
    <div className="video-preview-meta"><span><small>Format</small><strong>{video.orientation}</strong></span><span><small>Questions</small><strong>{video.question_count}</strong></span><span><small>Runtime</small><strong>{formatDuration(video.duration_seconds)}</strong></span><span><small>File size</small><strong>{video.file_bytes ? formatBytes(video.file_bytes) : '-'}</strong></span></div>
    <div className="video-preview-sets"><small>SOURCE SETS</small><span>{video.selections.map((item) => item.title || `Set ${item.number}`).join(' · ')}</span></div>
    <div className="dialog-actions"><button className="button secondary" onClick={onClose}>Close</button>{ready && <a className="button primary" href={video.download_url}><Download size={15} />Download MP4</a>}</div>
  </div></section></div>
}

function StatusIcon({ status }) {
  if (status === 'ready' || status === 'published') return <span className={`status-icon ${status}`}><Check size={16} /></span>
  if (status === 'attention') return <span className="status-icon attention"><CircleAlert size={16} /></span>
  return <span className="status-icon blocked"><CircleDashed size={16} /></span>
}

function CategoryInspector({ category, onEdit }) {
  return <aside className="context-inspector">
    <div className="inspector-title"><div><Gauge size={16} /><strong>Category overview</strong></div><button className="icon-button quiet" title="Edit category metadata" onClick={onEdit}><Pencil size={15} /></button></div>
    <div className="inspector-scroll">
      <div className="category-art">{category.thumbnail_url ? <img src={category.thumbnail_url} alt={`${category.name} selector`} /> : <Layers3 size={36} />}</div>
      <div className="inspector-block"><span className="inspector-label">DISPLAY TITLE</span><strong>{category.display_title || 'Not set'}</strong></div>
      <div className="inspector-block"><span className="inspector-label">APP DISPLAY TAG</span><strong>{category.display_tag || 'Not set'}</strong></div>
      <div className="inspector-block"><span className="inspector-label">WORKSPACE</span><code>{category.slug}</code></div>
      <div className="inspector-block"><span className="inspector-label">METADATA</span><StatusBadge status={category.metadata?.ready ? 'ready' : 'attention'} label={category.metadata?.ready ? 'Complete' : 'Needs attention'} />{category.metadata?.missing?.length > 0 && <small className="metadata-missing">{category.metadata.missing.join(', ')}</small>}</div>
      <div className="inspector-block"><span className="inspector-label">NEXT FOCUS</span><div className="focus-row"><StatusIcon status={category.next_action.status} /><span><strong>{category.next_action.label}</strong><small>{category.next_action.detail}</small></span></div></div>
      <div className="inspector-block"><span className="inspector-label">SOURCE INVENTORY</span><dl className="compact-list"><div><dt>Answer images</dt><dd>{category.answer_images.total}</dd></div><div><dt>Category images</dt><dd>{category.category_images.total}</dd></div><div><dt>Audio pairs</dt><dd>{category.audio_count}</dd></div><div><dt>Bundle version</dt><dd>{category.bundle?.bundle_version || '-'}</dd></div></dl></div>
    </div>
  </aside>
}

function categorySlug(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'quiz'
}

function defaultDisplayTitle(value) {
  const name = value.trim().toUpperCase()
  return name ? `${name} QUIZ` : ''
}

function defaultDisplayTag(value) {
  return value.trim().slice(0, 12).trim()
}

function CategoryDialog({ category, onClose, onSaved }) {
  const editing = Boolean(category)
  const [form, setForm] = useState({
    name: category?.name || '',
    display_title: category?.display_title || '',
    display_tag: category?.display_tag || '',
    description: category?.description || '',
    editorial_brief: category?.editorial_brief || '',
    age_min: category?.age_min || 5,
    age_max: category?.age_max || 10,
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const slug = category?.slug || categorySlug(form.name)

  function changeName(value) {
    setForm((current) => {
      const priorAutomatic = !current.display_title || current.display_title === defaultDisplayTitle(current.name)
      const priorAutomaticTag = !current.display_tag || current.display_tag === defaultDisplayTag(current.name)
      return {
        ...current,
        name: value,
        display_title: priorAutomatic ? defaultDisplayTitle(value) : current.display_title,
        display_tag: priorAutomaticTag ? defaultDisplayTag(value) : current.display_tag,
      }
    })
  }

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')
    const payload = {
      ...form,
      age_min: Number(form.age_min),
      age_max: Number(form.age_max),
      ...(editing ? {} : { slug }),
    }
    try {
      const saved = editing
        ? await patch(`/api/studio/categories/${category.slug}`, payload)
        : await post('/api/studio/categories', payload)
      await onSaved(saved)
    } catch (requestError) {
      setError(requestError.message)
      setBusy(false)
    }
  }

  return <div className="dialog-backdrop"><section className="dialog category-dialog" role="dialog" aria-modal="true">
    <header><div><p className="kicker">CATEGORY WORKSPACE</p><h2>{editing ? 'Edit category metadata' : 'Create category'}</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header>
    <form onSubmit={submit}>
      <div className="dialog-grid"><label>Category name<input autoFocus={!editing} required disabled={editing} title={editing ? 'Category name is fixed after creation' : undefined} minLength="2" maxLength="80" value={form.name} onChange={(event) => changeName(event.target.value)} /></label><label>Display title<input required minLength="2" maxLength="80" value={form.display_title} onChange={(event) => setForm({ ...form, display_title: event.target.value })} /></label></div>
      <label><span className="field-label-row"><span>App display tag</span><small>{form.display_tag.length}/12</small></span><input required minLength="1" maxLength="12" value={form.display_tag} onChange={(event) => setForm({ ...form, display_tag: event.target.value })} /></label>
      <label>Workspace slug<input value={slug} disabled /></label>
      <label>Short description<textarea required minLength="10" maxLength="300" rows="2" value={form.description} onChange={(event) => setForm({ ...form, description: event.target.value })} /></label>
      <label>Editorial brief<textarea required minLength="20" maxLength="1200" rows="5" value={form.editorial_brief} onChange={(event) => setForm({ ...form, editorial_brief: event.target.value })} /></label>
      <div className="dialog-grid"><label>Minimum age<input required type="number" min="3" max="15" value={form.age_min} onChange={(event) => setForm({ ...form, age_min: event.target.value })} /></label><label>Maximum age<input required type="number" min="3" max="15" value={form.age_max} onChange={(event) => setForm({ ...form, age_max: event.target.value })} /></label></div>
      {error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}
      <div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy}>{busy ? <LoaderCircle className="spin" size={15} /> : editing ? <Save size={15} /> : <Plus size={15} />}{editing ? 'Save metadata' : 'Create category'}</button></div>
    </form>
  </section></div>
}

function EmptyState({ icon: Icon, title, detail }) {
  return <div className="empty-state"><Icon size={30} /><strong>{title}</strong>{detail && <span>{detail}</span>}</div>
}

function ProviderAdmin({ providers, selectedId, onSelect, onReload, onJob, onCreate }) {
  const selected = providers.find((item) => item.id === selectedId) || providers[0]
  return <main className="admin-layout">
    <aside className="provider-sidebar">
      <div className="sidebar-heading"><div><span>ADMINISTRATION</span><strong>Connections</strong></div><button className="icon-button quiet" title="Add provider connection" onClick={onCreate}><Plus size={17} /></button></div>
      <div className="provider-list">
        {providers.map((provider) => <ProviderListItem provider={provider} selected={provider.id === selected?.id} onClick={() => onSelect(provider.id)} key={provider.id} />)}
      </div>
      <div className="provider-legend"><KeyRound size={15} /><span>Secrets are encrypted at rest</span></div>
    </aside>
    {selected ? <ProviderEditor provider={selected} onSaved={onReload} onJob={onJob} /> : <EmptyState icon={Server} title="No provider connections" />}
    {selected && <ProviderDiagnostics provider={selected} />}
  </main>
}

function ProviderListItem({ provider, selected, onClick }) {
  const meta = PROVIDER_META[provider.provider_type]
  const Icon = meta.icon
  return <button className={`provider-item ${selected ? 'selected' : ''}`} onClick={onClick}>
    <span className={`provider-icon ${meta.tone}`}><Icon size={18} /></span>
    <span><strong>{provider.name}</strong><small>{meta.label}</small></span>
    <span className={`health-dot ${provider.health_status}`} />
  </button>
}

function ProviderEditor({ provider, onSaved, onJob }) {
  const [form, setForm] = useState(providerForm(provider))
  const [saving, setSaving] = useState(false)
  const [testing, setTesting] = useState(false)
  const [uploadingReference, setUploadingReference] = useState(false)
  const [notice, setNotice] = useState('')

  useEffect(() => { setForm(providerForm(provider)); setNotice('') }, [provider])

  function change(key, value) { setForm((current) => ({ ...current, [key]: value })) }
  function setting(key, value) { setForm((current) => ({ ...current, settings: { ...current.settings, [key]: value } })) }

  async function persist() {
    setSaving(true)
    setNotice('')
    try {
      const payload = { name: form.name, base_url: form.base_url, default_model: form.default_model || null, enabled: form.enabled, settings: form.settings }
      if (form.api_key) payload.api_key = form.api_key
      await patch(`/api/admin/providers/${provider.id}`, payload)
      await onSaved(provider.id)
      return true
    } catch (error) {
      setNotice(error.message)
      return false
    } finally { setSaving(false) }
  }

  async function save(event) {
    event.preventDefault()
    if (await persist()) setNotice('Connection saved')
  }

  async function test() {
    setTesting(true)
    setNotice('')
    try {
      if (!(await persist())) return
      const job = await post(`/api/admin/providers/${provider.id}/test`)
      onJob(job)
      setNotice(provider.provider_type === 'vibevoice' ? 'Voice sample queued' : 'Connection test queued')
    } catch (error) { setNotice(error.message) } finally { setTesting(false) }
  }

  async function uploadReference(event) {
    const file = event.target.files?.[0]
    if (!file) return
    setUploadingReference(true)
    setNotice('')
    try {
      const result = await upload(`/api/admin/providers/${provider.id}/reference-audio`, file)
      await onSaved(provider.id)
      setNotice(`Reference WAV uploaded · ${result.reference_audio.duration_seconds}s`)
    } catch (error) { setNotice(error.message) } finally {
      setUploadingReference(false)
      event.target.value = ''
    }
  }

  const meta = PROVIDER_META[provider.provider_type]
  const Icon = meta.icon
  return <section className="provider-editor">
    <header className="editor-heading"><div className={`provider-icon large ${meta.tone}`}><Icon size={22} /></div><div><p className="kicker">{meta.label.toUpperCase()}</p><h1>{provider.name}</h1><p>{provider.base_url}</p></div><StatusBadge status={provider.health_status} /></header>
    <form onSubmit={save} className="editor-form">
      <div className="form-section"><div className="form-section-title"><span>Connection</span><small>Endpoint and authentication</small></div><div className="form-grid">
        <label>Display name<input value={form.name} onChange={(event) => change('name', event.target.value)} /></label>
        <label className="span-2">Base URL<input value={form.base_url} onChange={(event) => change('base_url', event.target.value)} spellCheck="false" /></label>
        <label className="span-2">API key <span className="label-note">{provider.has_secret ? `Configured ${provider.secret_hint}` : 'Not configured'}</span><input type="password" autoComplete="new-password" placeholder={provider.has_secret ? 'Enter a replacement key' : 'Enter API key if required'} value={form.api_key} onChange={(event) => change('api_key', event.target.value)} /></label>
      </div></div>
      <div className="form-section"><div className="form-section-title"><span>Runtime defaults</span><small>Captured with every generation job</small></div><div className="form-grid">
        <label>Default model<input list={`models-${provider.id}`} placeholder="Discovered automatically" value={form.default_model} onChange={(event) => change('default_model', event.target.value)} /><datalist id={`models-${provider.id}`}>{provider.discovered_models.map((model) => <option value={model} key={model} />)}</datalist></label>
        {provider.provider_type === 'openai_images' && <label>Question model<input placeholder="gpt-5.6-luna" value={form.settings.question_model || ''} onChange={(event) => setting('question_model', event.target.value)} /></label>}
        <label className="toggle-field"><span>Connection enabled</span><button type="button" className={`toggle ${form.enabled ? 'on' : ''}`} onClick={() => change('enabled', !form.enabled)} aria-pressed={form.enabled}><span /></button></label>
      </div></div>
      {provider.provider_type === 'vibevoice' && <VibeVoiceFields form={form} setting={setting} onUpload={uploadReference} uploading={uploadingReference} />}
      <div className="editor-actions"><button type="button" className="button secondary" onClick={test} disabled={testing || saving}>{testing ? <LoaderCircle className="spin" size={16} /> : <TestTube2 size={16} />}{provider.provider_type === 'vibevoice' ? 'Generate test clip' : 'Test connection'}</button><button className="button primary" disabled={saving}>{saving ? <LoaderCircle className="spin" size={16} /> : <Save size={16} />}Save changes</button></div>
      {notice && <div className={notice.includes('saved') || notice.includes('queued') ? 'form-notice success' : 'form-notice'}>{notice}</div>}
    </form>
  </section>
}

function providerForm(provider) {
  const settings = { ...provider.settings }
  if (provider.provider_type === 'openai_images' && !settings.question_model) settings.question_model = 'gpt-5.6-luna'
  return { name: provider.name, base_url: provider.base_url, api_key: '', default_model: provider.default_model || '', enabled: provider.enabled, settings }
}

function VibeVoiceFields({ form, setting, onUpload, uploading }) {
  return <div className="form-section"><div className="form-section-title"><span>Narrator profile</span><small>Reference voice and rendering defaults</small></div><div className="form-grid">
    <div className="span-2 provider-upload-field"><span>Reference audio</span><div><input value={form.settings.reference_audio_path || ''} onChange={(event) => setting('reference_audio_path', event.target.value)} spellCheck="false" /><label className="button secondary upload-button">{uploading ? <LoaderCircle className="spin" size={14} /> : <Upload size={14} />}Upload WAV<input type="file" accept="audio/wav,.wav" disabled={uploading} onChange={onUpload} /></label></div></div>
    <label className="span-2">Reference transcript<textarea rows="4" value={form.settings.reference_transcript || ''} onChange={(event) => setting('reference_transcript', event.target.value)} /></label>
    <label>Language<input value={form.settings.language || 'en_indian'} onChange={(event) => setting('language', event.target.value)} /></label>
    <label>CFG scale<input type="number" min="0.1" max="5" step="0.1" value={form.settings.cfg_scale || 1.3} onChange={(event) => setting('cfg_scale', Number(event.target.value))} /></label>
    <label className="span-2">Test phrase<textarea rows="3" value={form.settings.test_phrase || ''} onChange={(event) => setting('test_phrase', event.target.value)} /></label>
  </div></div>
}

function ProviderDiagnostics({ provider }) {
  const checked = provider.last_checked_at ? new Date(provider.last_checked_at).toLocaleString() : 'Not checked'
  return <aside className="provider-diagnostics">
    <div className="inspector-title"><div><Activity size={16} /><strong>Diagnostics</strong></div></div>
    <div className="inspector-scroll">
      <div className={`diagnostic-health ${provider.health_status}`}>{provider.health_status === 'healthy' ? <CheckCircle2 size={24} /> : provider.health_status === 'unhealthy' ? <CircleAlert size={24} /> : <Server size={24} />}<div><strong>{provider.health_status.replaceAll('_', ' ')}</strong><span>{provider.health_message || 'Run a connection test to verify this provider.'}</span></div></div>
      <div className="inspector-block"><span className="inspector-label">LAST CHECKED</span><strong>{checked}</strong></div>
      <div className="inspector-block"><span className="inspector-label">DISCOVERED MODELS</span>{provider.discovered_models.length ? <div className="model-list">{provider.discovered_models.map((model) => <span className={model === provider.default_model ? 'selected' : ''} key={model}>{model}{model === provider.default_model && <Check size={13} />}</span>)}</div> : <p className="muted-copy">No models discovered yet.</p>}</div>
      <div className="inspector-block"><span className="inspector-label">SECRET</span><div className="secret-state"><KeyRound size={16} /><span><strong>{provider.has_secret ? 'Encrypted key stored' : 'No key configured'}</strong><small>{provider.has_secret ? provider.secret_hint : 'Local endpoints may not require one'}</small></span></div></div>
    </div>
  </aside>
}

function AddProviderDialog({ onClose, onCreated }) {
  const [form, setForm] = useState({ provider_type: 'imagestudio', name: 'ImageStudio', base_url: 'http://127.0.0.1:8000', api_key: '' })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  function changeType(provider_type) {
    const defaults = { imagestudio: ['ImageStudio', 'http://127.0.0.1:8000'], openai_images: ['OpenAI Images', 'https://api.openai.com/v1'], openai_compatible_llm: ['Quiz planning LLM', 'http://127.0.0.1:8001/v1'], vibevoice: ['Quiz narrator', 'http://127.0.0.1:8092'] }
    setForm({ provider_type, name: defaults[provider_type][0], base_url: defaults[provider_type][1], api_key: '' })
  }
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    try { const created = await post('/api/admin/providers', form); await onCreated(created.id) } catch (requestError) { setError(requestError.message); setBusy(false) }
  }
  return <div className="dialog-backdrop" role="presentation"><section className="dialog" role="dialog" aria-modal="true" aria-labelledby="add-provider-title">
    <header><div><p className="kicker">ADMINISTRATION</p><h2 id="add-provider-title">Add connection</h2></div><button className="icon-button quiet" title="Close" onClick={onClose}><X size={18} /></button></header>
    <form onSubmit={submit}><label>Provider type<select value={form.provider_type} onChange={(event) => changeType(event.target.value)}>{Object.entries(PROVIDER_META).map(([id, item]) => <option value={id} key={id}>{item.label}</option>)}</select></label><label>Display name<input required value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} /></label><label>Base URL<input required value={form.base_url} onChange={(event) => setForm({ ...form, base_url: event.target.value })} /></label><label>API key <span className="label-note">Optional for local services</span><input type="password" value={form.api_key} onChange={(event) => setForm({ ...form, api_key: event.target.value })} /></label>{error && <div className="inline-error"><CircleAlert size={15} />{error}</div>}<div className="dialog-actions"><button type="button" className="button secondary" onClick={onClose}>Cancel</button><button className="button primary" disabled={busy}>{busy ? <LoaderCircle className="spin" size={16} /> : <Plus size={16} />}Add connection</button></div></form>
  </section></div>
}

function JobsDrawer({ jobs, expanded, onToggle }) {
  const active = jobs.filter((job) => ['queued', 'running'].includes(job.status))
  return <footer className={`jobs-drawer ${expanded ? 'expanded' : ''}`}>
    <button className="jobs-handle" onClick={onToggle}><span className="jobs-icon"><Activity size={17} /></span><span><strong>Activity</strong><small>{active.length ? `${active.length} job${active.length === 1 ? '' : 's'} running` : jobs.length ? 'All jobs settled' : 'No recent activity'}</small></span>{active.length > 0 && <span className="active-job"><LoaderCircle className="spin" size={14} />{active[0].message}</span>}<ChevronDown className={expanded ? 'rotate' : ''} size={18} /></button>
    {expanded && <div className="jobs-list">{jobs.length ? jobs.slice(0, 8).map((job) => <div className="job-row" key={job.id}><StatusIcon status={job.status === 'complete' ? 'ready' : job.status === 'failed' ? 'attention' : 'blocked'} /><div><strong>{job.kind.replaceAll('_', ' ')}</strong><small>{job.message}{job.error ? `: ${job.error}` : job.result?.warning ? `: ${job.result.warning}` : ''}</small></div><div className="job-progress"><span><i style={{ width: `${Math.round(job.progress * 100)}%` }} /></span><small>{Math.round(job.progress * 100)}%</small></div><StatusBadge status={job.status} />{job.result?.sample_audio && <audio controls preload="none" src={job.result.sample_audio} />}</div>) : <EmptyState icon={Activity} title="No jobs yet" />}</div>}
  </footer>
}

export default function App() {
  const [authenticated, setAuthenticated] = useState(null)
  const [view, setView] = useState('workspace')
  const [activeStage, setActiveStage] = useState('overview')
  const [categories, setCategories] = useState([])
  const [selectedSlug, setSelectedSlug] = useState('animals')
  const [providers, setProviders] = useState([])
  const [selectedProviderId, setSelectedProviderId] = useState('')
  const [jobs, setJobs] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [jobsOpen, setJobsOpen] = useState(false)
  const [addingProvider, setAddingProvider] = useState(false)
  const [categoryDialog, setCategoryDialog] = useState(null)
  const [studioRevision, setStudioRevision] = useState(0)

  async function loadCategories(preferredSlug) {
    const payload = await api('/api/studio/categories')
    setCategories(payload.categories)
    const preferred = preferredSlug || selectedSlug
    if (!payload.categories.some((item) => item.slug === preferred)) setSelectedSlug(payload.categories[0]?.slug || '')
    else if (preferredSlug) setSelectedSlug(preferredSlug)
  }
  async function loadProviders(preferredId) {
    const payload = await api('/api/admin/providers')
    setProviders(payload.providers)
    const preferred = preferredId || selectedProviderId
    setSelectedProviderId(payload.providers.some((item) => item.id === preferred) ? preferred : payload.providers[0]?.id || '')
  }
  async function loadJobs() { const payload = await api('/api/studio/jobs'); setJobs(payload.jobs) }
  async function loadStudio() {
    setLoading(true); setError('')
    try { await Promise.all([loadCategories(), loadProviders(), loadJobs()]) } catch (requestError) { setError(requestError.message) } finally { setLoading(false) }
  }

  useEffect(() => { api('/api/auth/status').then((result) => setAuthenticated(result.authenticated)).catch(() => setAuthenticated(false)) }, [])
  useEffect(() => { if (authenticated) loadStudio() }, [authenticated])

  const activeJobIds = useMemo(() => jobs.filter((job) => ['queued', 'running'].includes(job.status)).map((job) => job.id).sort().join(','), [jobs])
  useEffect(() => {
    if (!activeJobIds) return undefined
    const streams = activeJobIds.split(',').map((jobId) => {
      const stream = new EventSource(`/api/studio/jobs/${jobId}/events`)
      stream.addEventListener('job', (event) => {
        const update = JSON.parse(event.data)
        setJobs((current) => current.map((job) => job.id === jobId ? { ...job, status: update.status, message: update.message, progress: update.progress, updated_at: update.created_at } : job))
      })
      stream.addEventListener('complete', async (event) => {
        const complete = JSON.parse(event.data)
        setJobs((current) => current.map((job) => job.id === jobId ? complete : job))
        stream.close()
        await Promise.all([loadProviders(), loadCategories()])
        setStudioRevision((current) => current + 1)
      })
      stream.onerror = () => stream.close()
      return stream
    })
    return () => streams.forEach((stream) => stream.close())
  }, [activeJobIds])

  useEffect(() => {
    if (!activeJobIds) return undefined
    const timer = window.setInterval(() => loadJobs().catch(() => {}), 2500)
    return () => window.clearInterval(timer)
  }, [activeJobIds])

  const selectedCategory = categories.find((item) => item.slug === selectedSlug) || categories[0]
  const healthyProviders = providers.filter((item) => item.health_status === 'healthy').length

  async function logout() { await post('/api/auth/logout'); setAuthenticated(false) }
  function registerJob(job) { setJobs((current) => [job, ...current.filter((item) => item.id !== job.id)]); setJobsOpen(true) }
  async function providerCreated(id) { setAddingProvider(false); await loadProviders(id) }
  async function categorySaved(category) { setCategoryDialog(null); await loadCategories(category.slug); setActiveStage('overview'); setStudioRevision((current) => current + 1) }

  if (authenticated === null) return <div className="app-loading"><LoaderCircle className="spin" size={28} /></div>
  if (!authenticated) return <LoginPage onLogin={() => setAuthenticated(true)} />

  return <div className="app-shell">
    <AppHeader view={view} category={selectedCategory} onView={setView} onLogout={logout} healthyProviders={healthyProviders} totalProviders={providers.length} />
    {error && <div className="global-error"><CircleAlert size={17} /><span>{error}</span><button title="Dismiss" onClick={() => setError('')}><X size={16} /></button></div>}
    {view === 'workspace' ? <main className="workspace-shell"><CategorySidebar categories={categories} selected={selectedSlug} onSelect={setSelectedSlug} loading={loading} onRefresh={loadCategories} onCreate={() => setCategoryDialog('create')} />{activeStage === 'questions' ? <QuestionBankWorkspace category={selectedCategory} providers={providers} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} onCategoryRefresh={loadCategories} /> : activeStage === 'sets' ? <QuizSetsWorkspace category={selectedCategory} providers={providers} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} onCategoryRefresh={loadCategories} /> : activeStage === 'visuals' ? <VisualsWorkspace category={selectedCategory} providers={providers} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} onCategoryRefresh={loadCategories} /> : activeStage === 'audio' ? <AudioWorkspace category={selectedCategory} providers={providers} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} onCategoryRefresh={loadCategories} /> : activeStage === 'publish' ? <PublishWorkspace category={selectedCategory} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} onCategoryRefresh={loadCategories} /> : activeStage === 'video' ? <VideoWorkspace category={selectedCategory} onStage={setActiveStage} onJob={registerJob} refreshToken={studioRevision} /> : <OverviewWorkspace category={selectedCategory} onStage={setActiveStage} onEdit={() => setCategoryDialog(selectedCategory)} />}</main> : <ProviderAdmin providers={providers} selectedId={selectedProviderId} onSelect={setSelectedProviderId} onReload={loadProviders} onJob={registerJob} onCreate={() => setAddingProvider(true)} />}
    <JobsDrawer jobs={jobs} expanded={jobsOpen} onToggle={() => setJobsOpen((current) => !current)} />
    {addingProvider && <AddProviderDialog onClose={() => setAddingProvider(false)} onCreated={providerCreated} />}
    {categoryDialog && <CategoryDialog category={categoryDialog === 'create' ? null : categoryDialog} onClose={() => setCategoryDialog(null)} onSaved={categorySaved} />}
  </div>
}
