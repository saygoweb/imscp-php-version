<?php
/**
 * i-MSCP SGW_PhpVersion plugin
 * Copyright (C) 2026 Cambell Prince <cambell.prince@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

namespace SGW_PhpVersion;

/**
 * The <option> list for a version selector.
 *
 * The options are built here rather than as a template block because both
 * pages need the same list once per row, and a block would have to be reset
 * between rows. The empty value means "whatever the panel default is", which
 * is a real choice and not a placeholder: a domain left on it follows the
 * panel when the administrator moves the default.
 *
 * @param array $versions Version string => is it the panel default?
 * @param string|null $selected Version to preselect, or NULL for none
 * @return string
 */
function versionOptions(array $versions, $selected)
{
    $default = defaultVersion();
    $html = sprintf(
        '<option value=""%s>%s</option>',
        // The default is only preselected as the empty option when the domain
        // has no choice recorded; a domain explicitly pinned to the version
        // that happens to be the default shows as pinned.
        ($selected === '' ? ' selected' : ''),
        tohtml($default === ''
            ? tr('Panel default')
            : tr('Panel default (%s)', $default))
    );

    foreach (array_keys($versions) as $version) {
        $html .= sprintf(
            '<option value="%s"%s>%s</option>',
            tohtml($version, 'htmlAttr'),
            ($selected === $version ? ' selected' : ''),
            tohtml(tr('PHP %s', $version))
        );
    }

    return $html;
}

/**
 * What a domain is running, said in words.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @param array $versions Version string => is it the panel default?
 * @return string
 */
function versionLabel(array $domain, array $versions)
{
    $current = chosenVersion($domain);

    if ($current === '') {
        return tr('unknown');
    }

    // A version a customer is pinned to that is no longer installed is worth
    // saying out loud: the backend will have fallen back to the default.
    if (!array_key_exists($current, $versions)) {
        return tr('%s (not installed)', $current);
    }

    return sprintf('%s%s', $current,
        rawVersion($domain) === '' ? ' ' . tr('(default)') : '');
}
