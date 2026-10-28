import Foundation

/// Only installed on demand in a private WebKit content world. Pages cannot call the bridge.
enum AgentDOMScript {
    static let source = #"""
    const fail = message => ({error: message});
    const clean = (text, limit = 200) => String(text || '').replace(/\s+/g, ' ').trim().slice(0, limit);
    const roots = () => {
        const result = [document];
        for (let index = 0; index < result.length && result.length < 100; index++) {
            for (const element of result[index].querySelectorAll('*')) {
                if (element.shadowRoot) result.push(element.shadowRoot);
            }
        }
        return result;
    };
    const visible = element => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return element.isConnected && !element.closest('[inert],[hidden],[aria-hidden="true"]') &&
            style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) !== 0 &&
            rect.width > 0 && rect.height > 0;
    };
    const viewport = element => {
        const rect = element.getBoundingClientRect();
        return visible(element) && rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
    };
    const role = element => {
        if (element.getAttribute('role')) return element.getAttribute('role');
        const tag = element.tagName.toLowerCase();
        if (tag === 'a' && element.hasAttribute('href')) return 'link';
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'textarea' || element.isContentEditable) return 'textbox';
        if (tag === 'select') return element.multiple ? 'listbox' : 'combobox';
        if (tag === 'input') {
            const type = (element.type || 'text').toLowerCase();
            return ({checkbox:'checkbox',radio:'radio',range:'slider',button:'button',submit:'button',reset:'button',number:'spinbutton',search:'searchbox'})[type] || 'textbox';
        }
        if (/^h[1-6]$/.test(tag)) return 'heading';
        return 'generic';
    };
    const name = element => {
        const labelled = (element.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => {
            const target = element.getRootNode().getElementById?.(id) || document.getElementById(id);
            return target?.textContent || '';
        }).join(' ');
        return clean(element.getAttribute('aria-label') || labelled.trim() ||
            (element.labels ? [...element.labels].map(label => label.innerText).join(' ') : '') ||
            element.getAttribute('alt') || element.getAttribute('title') ||
            (element.matches('input[type=submit],input[type=button],input[type=reset]') ? element.value : '') ||
            element.innerText || element.getAttribute('placeholder'));
    };
    if (args.operation === 'snapshot') {
        const elements = [];
        const refs = new Map();
        const prefix = 'e' + Math.random().toString(36).slice(2, 10);
        const selector = 'a[href],button,input:not([type=hidden]),textarea,select,summary,[contenteditable=true],[role],h1,h2,h3,h4,h5,h6,[tabindex]';
        let truncated = false;
        for (const root of roots()) {
            for (const element of root.querySelectorAll(selector)) {
                if (!viewport(element)) continue;
                if (elements.length >= 300) { truncated = true; break; }
                const ref = prefix + '-' + elements.length;
                refs.set(ref, element);
                const rect = element.getBoundingClientRect();
                const item = {ref, role:role(element), name:name(element), tag:element.tagName.toLowerCase(),
                    disabled:!!element.disabled || element.getAttribute('aria-disabled') === 'true',
                    rect:{x:Math.round(rect.x),y:Math.round(rect.y),width:Math.round(rect.width),height:Math.round(rect.height)}};
                if (element.matches('input[type=checkbox],input[type=radio]')) item.checked = element.checked;
                if (element.matches('input:not([type=password]):not([type=hidden]),textarea,select')) item.value = clean(element.value, 500);
                if (element.matches('a[href]')) item.href = element.href;
                elements.push(item);
            }
        }
        globalThis.__featherAgentRefs = {refs, document, url:location.href};
        return {url:location.href,title:document.title,viewport:{width:innerWidth,height:innerHeight},
            text:clean(document.body?.innerText, 32000),elements,truncated,
            limitations:['Main document and open shadow roots only. Use native computer use for cross-origin frames, closed shadow roots, and trusted input.']};
    }
    if (args.operation === 'scroll') {
        const x = args.x ?? 0, y = args.y ?? innerHeight * 0.8;
        if (typeof x !== 'number' || typeof y !== 'number' || !Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) > 100000 || Math.abs(y) > 100000) return fail('Scroll offsets must be finite numbers within 100000 pixels.');
        window.scrollBy({left:x,top:y,behavior:'instant'});
        return {scrolled:true,x:scrollX,y:scrollY};
    }
    let element;
    if (args.ref != null && args.selector != null) return fail('Provide ref or selector, not both.');
    if (typeof args.ref === 'string') {
        const saved = globalThis.__featherAgentRefs;
        if (!saved || saved.document !== document || saved.url !== location.href) return fail('Stale element reference. Take a new snapshot.');
        element = saved.refs.get(args.ref);
        if (!element?.isConnected) return fail('Stale element reference. Take a new snapshot.');
    } else if (typeof args.selector === 'string' && args.selector.length > 0 && args.selector.length <= 2000) {
        let matches;
        try { matches = roots().flatMap(root => [...root.querySelectorAll(args.selector)]).filter(visible); }
        catch { return fail('Invalid CSS selector.'); }
        if (matches.length !== 1) return fail('Selector must match exactly one visible element; found ' + matches.length + '.');
        element = matches[0];
    } else return fail('Provide an element ref from a snapshot or a CSS selector.');
    if (!visible(element)) return fail('Element is hidden or detached. Take a new snapshot.');
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') return fail('Element is disabled.');
    element.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
    if (args.operation === 'click') {
        const rect = element.getBoundingClientRect();
        const root = element.getRootNode();
        const hit = (root.elementFromPoint?.(Math.max(0,rect.left + rect.width / 2),Math.max(0,rect.top + rect.height / 2)) || document.elementFromPoint(rect.left + rect.width / 2,rect.top + rect.height / 2));
        if (hit && hit !== element && !element.contains(hit)) return fail('Element is covered by another element.');
        element.focus();
        element.click();
        return {clicked:true};
    }
    if (args.operation === 'fill') {
        if (typeof args.value !== 'string' || args.value.length > 32000) return fail('value must be a string of at most 32000 characters.');
        if (element.readOnly) return fail('Element is read-only.');
        element.focus();
        if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
            if (element instanceof HTMLInputElement && /^(file|checkbox|radio|button|submit|reset|image|hidden)$/.test(element.type)) return fail('This input cannot be filled.');
            const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype,'value').set.call(element,args.value);
        } else if (element.isContentEditable) element.textContent = args.value;
        else return fail('Element is not an editable text field.');
        element.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,inputType:'insertText',data:args.value}));
        element.dispatchEvent(new Event('change',{bubbles:true}));
        return {filled:true};
    }
    if (args.operation === 'select') {
        if (!(element instanceof HTMLSelectElement) || typeof args.value !== 'string') return fail('Use a select element and a string option value.');
        if (![...element.options].some(option => option.value === args.value && !option.disabled)) return fail('No enabled option matches value.');
        element.value = args.value;
        element.dispatchEvent(new Event('input',{bubbles:true}));
        element.dispatchEvent(new Event('change',{bubbles:true}));
        return {selected:true};
    }
    if (args.operation === 'press') {
        if (!['Enter','Tab','Escape'].includes(args.key)) return fail('Unsupported key. Supported keys: Enter, Tab, Escape. Use native computer use for text editing, keyboard shortcuts, and trusted key input.');
        element.focus();
        const accepted = element.dispatchEvent(new KeyboardEvent('keydown',{key:args.key,bubbles:true,cancelable:true,composed:true}));
        if (accepted && args.key === 'Enter') {
            if (element instanceof HTMLInputElement && element.form) element.form.requestSubmit();
            else if (element.matches('button,a[href],summary')) element.click();
        }
        if (accepted && args.key === 'Tab') {
            const controls = roots().flatMap(root => [...root.querySelectorAll('a[href],button,input,textarea,select,[tabindex]')]).filter(item => visible(item) && !item.disabled && item.tabIndex >= 0);
            const index = controls.indexOf(element);
            controls[(index + 1) % controls.length]?.focus();
        }
        element.dispatchEvent(new KeyboardEvent('keyup',{key:args.key,bubbles:true,composed:true}));
        return {dispatched:true,trusted:false};
    }
    return fail('Unknown page operation.');
    """#
}
