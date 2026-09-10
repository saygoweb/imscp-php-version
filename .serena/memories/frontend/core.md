# frontend/ — the panel half

## Files

- `SGW_PhpVersion.php` (repo root) — the `iMSCP\Plugin\AbstractPlugin` subclass. `getRoutes()` maps
  `/client/php_version.php` and `/reseller/php_version.php` onto `frontend/{client,reseller}/`.
  `register()` listens on `onResellerScriptStart`/`onClientScriptStart` (to inject the nav entry) and
  on `onAfterDeleteCustomer` / `onAfterDeleteDomainAlias` / `onAfterDeleteSubdomain`, which flip rows
  to `todelete` so a vanishing vhost takes its pool with it.
- `frontend/common.php` — namespace `SGW_PhpVersion`, plain functions, no classes. The vhost model.
- `frontend/view.php` — HTML fragment builders only.
- `frontend/{client,reseller}/php_version.php` — one page each: `handleSubmit()` then `generatePage()`,
  the i-MSCP page idiom (`define_dynamic`, `assign`, `parse`, `prnt`).
- `themes/default/view/…/php_version.tpl` — referenced from the page by the literal path
  `../../plugins/SGW_PhpVersion/themes/default/view/...`, i.e. the **installed** name.

## The one query

`fetchDomains($ownerCondition, $params)` is a four-arm `UNION ALL` over `domain`, `subdomain`,
`domain_aliasses`, `subdomain_alias`, each arm carrying `d.domain_php = 'yes'` and the caller's
predicate over the `domain` alias `d`. The predicate is spliced into every arm (hence `$params`
repeated four times), so the reseller page and the client page differ **by their WHERE clause alone**
— `getDomains($adminId)` vs `getResellerDomains($resellerId)`. Add a column or a join once and both
pages get it.

Rows are then filtered by `runsPhp()`: a vhost that forwards or proxies is built from the forward
template, has no PHP handler and gets no pool, so offering it a version would be offering something
that could never take effect.

## Rules the pages follow

- **The per-row `<select>`s are what the form submits.** The "set ticked rows to X" control is
  client-side jQuery that only fills them in, so what is about to happen is visible on screen before
  Apply. Keep it that way; do not add a server-side bulk path.
- Row keys are `domain_type . '-' . domain_id` (`domainKey()`). A hyphen, not a colon: the key lands
  both in an HTML attribute and in the jQuery selector that reads it back, where a colon would need
  escaping in one and mean something in the other.
- Submitted keys are matched against a freshly fetched owner-scoped list, never trusted; a submitted
  version that is not `''` and not in `php_version_installed` is a `showBadRequestErrorPage()`. A
  submitted pool is checked with `array_key_exists($pool, pools())` — **`''` is a legitimate key**
  there (it is the default instance), so it needs no special case the way the version does.
- `pools()` in `common.php` is `array('' => tr('Default'))` plus `config.php`'s `pools`, read through
  `Registry::get('pluginManager')->pluginGet('SGW_PhpVersion')->getConfigParam('pools', array())` and
  filtered by `^[a-z0-9][a-z0-9-]*$`. `rawPool()` drives the selector, `poolLabel()` the column (it
  says "(not configured)" for a pool since removed from `config.php`). `poolOptions()` in `view.php`
  is `versionOptions()`'s counterpart.
- There are **two independent bulk controls**, `#php_version_bulk_apply` writing `select[data-key]`
  and `#php_version_bulk_pool_apply` writing `select[data-pool-key]`, so a batch can be moved between
  pools without touching anybody's version. Both still only fill the per-row selects in.
- `setChoice($domain, $version, $pool)` writes two rows — this plugin's, and the vhost's own
  `*_status = 'tochange'`, which is what makes i-MSCP rebuild at all — then the page calls
  `send_request()` once. Version and pool are always written together; there is no set-just-the-pool
  path, and a row is skipped only when **both** are unchanged.
- Unsettled rows are rendered disabled and skipped on submit. The reseller page **counts** them and
  says so, because across a few hundred domains silence would be wrong; the client page just skips.
- `rawVersion()` (the recorded choice, `''` = follow the default) drives the selectors, so submitting
  a page unchanged records no change. `chosenVersion()` (what it resolves to) drives the "Running"
  column. Keep the two apart.
- Access: the client page requires `customerHasFeature('php')` and the reseller page
  `resellerHasCustomers()`, each checked **in both** the nav injection and the page itself. The two
  must stay in step: `shared/layouts/ui.tpl` reads a page's title and `title_class` off whichever
  navigation entry matches the request, so a page reachable by URL whose menu entry is hidden dies
  with `Call to a member function get() on null` instead of rendering. Every i-MSCP page behind such
  a condition asserts it right after `check_login()` for exactly this reason (0.2.1 bug).
- Everything user-visible goes through `tr()` and `tohtml()`; domain names through `decode_idna()`.
