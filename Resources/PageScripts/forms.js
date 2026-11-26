(function () {
  if (window.__yabForms) return;
  // WebKit stretches this SVG to a tall password box while keeping its
  // width at 17px. Keep the system Caps Lock mark's original proportions,
  // including in sign-in frames; WebKit still decides when it is shown.
  var controls = document.createElement('style');
  controls.textContent = 'input::-webkit-caps-lock-indicator { object-fit: contain; }';
  document.documentElement.appendChild(controls);
  // In another site's frame (App Store Connect signs in in Apple's) this
  // only says where its sign-in boxes are, hears one sent and its boxes
  // going: the rest is the page's.
  var framed = window.top !== window;

  // A box a person can see and type in: drawn, on the page rather than
  // moved off it, and not made see-through. A bot trap between the name
  // and the password is none of these.
  function seen(box) {
    var r = box.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0 || r.right <= 0 || r.bottom <= 0) return false;
    var style = window.getComputedStyle(box);
    return style.visibility !== 'hidden' && style.opacity !== '0';
  }

  // The password box, and the box before it that holds the name: the one
  // that says it is the username, else the last one a person can see,
  // else a hidden one the page filled (Google's password step keeps the
  // account in one). A hidden box left empty is a trap for bots, and a
  // name put there would give the sign-in away as a bot's.
  // A box for a few characters of a secret, as banks ask for the 2nd, 5th
  // and 7th of a memorable word, each in a hidden box of its own: never a
  // password to keep or fill.
  function partial(box) {
    if (box.maxLength > 0 && box.maxLength <= 3) return true;
    var words = [box.name, box.id, box.placeholder, box.getAttribute('aria-label'),
      box.labels && box.labels[0] && box.labels[0].textContent].join(' ');
    // "Character 2", "3rd letter", never a sign-up's "at least 8 characters".
    return /memorable|\b(\d+(st|nd|rd|th)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(character|letter|char)\b|\b(character|letter|char)\s*\d/i.test(words);
  }

  // A component can keep each box in a shadow root of its own (Reddit's
  // faceplate-text-input). Keep composed tree order so the name before a
  // password is still its name, including across sibling components.
  var listenedRoots = new WeakSet(), heardFocus = new WeakSet();
  var fieldHosts = new Set();
  function parent(node) {
    return node && (node.parentElement || (node.getRootNode && node.getRootNode().host));
  }
  function learn(box) {
    // Only enter roots on the focused field's composed ancestry. Once a
    // host type is known to contain fields, its siblings can be queried too.
    for (var node = box; node; node = parent(node)) {
      var root = node.getRootNode && node.getRootNode();
      if (!root || !root.host) continue;
      fieldHosts.add(root.host.localName);
      if (listenedRoots.has(root)) continue;
      listenedRoots.add(root);
      root.addEventListener('focusin', shadowFocus, true);
      root.addEventListener('focusout', shadowFocus, true);
      root.addEventListener('submit', function (event) {
        if (event.composedPath().indexOf(document) < 0) offer(null, event.target);
      }, true);
    }
  }
  function shadowFocus(event) {
    if (event.composedPath().indexOf(document) >= 0 || heardFocus.has(event)) return;
    heardFocus.add(event);
    if (event.type === 'focusout') setTimeout(caret, 0);
    else caret();
  }
  function boxesIn(scope, selector) {
    var found = [], hosts = Array.from(fieldHosts);
    function visit(root) {
      var nodes = root.querySelectorAll(selector + (hosts.length ? ',' + hosts.join(',') : ''));
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        if (node.matches(selector)) { found.push(node); if (node.matches('input')) learn(node); }
        if (node.shadowRoot && fieldHosts.has(node.localName)) visit(node.shadowRoot);
      }
    }
    visit(scope);
    return found;
  }
  function component(box) {
    var fallback = box && (box.getRootNode().host ? box.getRootNode() : box.parentElement);
    for (var node = parent(box); node && node !== document.documentElement; node = parent(node)) {
      if (boxesIn(node, 'input').length >= 2) return node;
    }
    return fallback || document;
  }

  // closest() and input.form stop at a shadow boundary. A form around
  // the component still owns its boxes; another form on the page does not.
  function formOf(box) {
    if (box.form) return box.form;
    for (var node = box; node; node = node.parentElement || (node.getRootNode && node.getRootNode().host)) {
      if (node.matches && node.matches('form, [role="form"]')) return node;
    }
    return null;
  }

  function pair(anchor, within) {
    var focused = anchor || inside(document.activeElement);
    if (focused) learn(focused);
    var scope = within || (focused && (formOf(focused) || component(focused))) || document;
    var boxes = boxesIn(scope, 'input[type="password"]');
    var pass = null;
    // Focus in the second of two sign-ins must never fill the first one.
    if (focused && boxes.indexOf(focused) >= 0 && seen(focused) && !partial(focused)) pass = focused;
    for (var p = 0; !pass && p < boxes.length; p++) {
      var b = boxes[p];
      var r = b.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && !partial(b)) { pass = b; break; }
    }
    if (!pass) return null;
    scope = formOf(pass) || component(pass);
    var all = boxesIn(scope, 'input');
    var said = null, shown = null, kept = null;
    for (var i = 0; i < all.length; i++) {
      if (all[i] === pass) break;
      var kind = (all[i].type || 'text').toLowerCase();
      if (kind !== 'text' && kind !== 'email' && kind !== 'tel') continue;
      var visible = seen(all[i]);
      var auto = (all[i].getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
      if (auto.indexOf('username') >= 0 && (visible || all[i].value)) said = all[i];
      if (visible) shown = all[i];
      else if (all[i].value) kept = all[i];
    }
    return { user: said || shown || kept, pass: pass };
  }

  // A box the page marked for passkey autofill (autocomplete="username
  // webauthn"), as Chromium's autofill reads the token: the rows under it
  // list the site's passkeys while a conditional get waits.
  function webauthn(box) {
    return !!(box && box.getAttribute &&
      (box.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('webauthn') >= 0);
  }
  // Its form takes passkeys, a box of it marked so: Chrome fills nothing
  // there by itself and waits for a pick (kAcceptsWebAuthnCredentials).
  function webauthnForm(box) {
    if (!box) return false;
    if (webauthn(box)) return true;
    var scope = formOf(box) || component(box);
    var all = scope ? boxesIn(scope, 'input') : [];
    for (var i = 0; i < all.length; i++) if (webauthn(all[i])) return true;
    return false;
  }

  // The first step of a sign-in that asks for the name alone, Google,
  // Microsoft, Apple, has no password box yet, and pair() finds nothing.
  // A box that says it holds the account name, with no password box in
  // its form, is that step. A form with more to fill in than a name is a
  // sign-up or a checkout, and is left alone.
  function lone(el) {
    if (!el || (el.tagName || '').toLowerCase() !== 'input') return null;
    // Authentication may have blurred the remembered field to the body.
    // Its form still decides, rather than a different sign-in on the page.
    if (pair(el)) return null;
    var kind = (el.type || 'text').toLowerCase();
    if (kind !== 'text' && kind !== 'email' && kind !== 'tel') return null;
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (auto.indexOf('username') >= 0 || webauthn(el)) return el;
    var named = kind === 'email' || auto.indexOf('email') >= 0 ||
      /user|login|email|e-mail|identifier|account/i.test((el.name || '') + ' ' + (el.id || ''));
    if (!named) return null;
    var scope = formOf(el) || component(el);
    var all = boxesIn(scope, 'input');
    var boxes = 0;
    for (var i = 0; i < all.length; i++) {
      var t = (all[i].type || 'text').toLowerCase();
      if (['text', 'email', 'tel', 'number', 'url'].indexOf(t) < 0) continue;
      var b = all[i].getBoundingClientRect();
      if (b.width > 0 && b.height > 0) boxes++;
    }
    return boxes <= 2 ? el : null;
  }

  // The name box of that first step, the last time the caret was in it:
  // what it held when the page moved on is the account the password
  // step is for.
  var named = null;

  // A document and its sign-in pair, rather than the URL: the same URL
  // can load a new page while Touch ID is being asked for the old one.
  var autoDocument = String(performance.timeOrigin) + ':' + Math.random().toString(36).slice(2);
  var autoFields = new WeakMap(), nextAutoField = 0;
  var lastCode = null;
  // A chosen account belongs to this exact field while its manager asks
  // for approval. A blur to the body keeps it; another editable cancels it.
  var lastSignIn = null, picked = null, nextPick = 0;
  function fieldState(box) {
    return box && { box: box, value: box.value, type: box.type,
      autocomplete: box.getAttribute('autocomplete'), form: formOf(box), disabled: box.disabled, readOnly: box.readOnly };
  }
  function unchanged(state) {
    if (!state) return true;
    var box = state.box;
    return box.isConnected && box.disabled === state.disabled && box.readOnly === state.readOnly && box.value === state.value &&
      box.type === state.type && box.getAttribute('autocomplete') === state.autocomplete && formOf(box) === state.form;
  }
  function fieldIdentity(box, both) {
    var anchor = both ? both.pass : box;
    if (!anchor) return '';
    if (!autoFields.has(anchor)) autoFields.set(anchor, String(++nextAutoField));
    return autoFields.get(anchor);
  }
  function visible(box) {
    var r = box.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function freshPassword(scope) {
    if (/sign.?up|register|registration|create.?account|reset.?password|change.?password|new.?password/i.test(location.pathname)) return true;
    var boxes = boxesIn(scope, 'input[type="password"]');
    var passwords = 0;
    for (var i = 0; i < boxes.length; i++) {
      var box = boxes[i];
      if (!visible(box)) continue;
      passwords++;
      if ((box.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('new-password') >= 0) return true;
      if (/new|confirm|repeat|verify/i.test((box.name || '') + ' ' + (box.id || ''))) return true;
    }
    if (passwords > 1) return true;
    var words = boxesIn(scope, 'button, input[type="submit"], [role="button"], h1, h2, h3');
    var signingIn = [].some.call(words, function (word) {
      var primary = /^H[123]$/.test(word.tagName) ||
        ((word.tagName === 'BUTTON' || word.tagName === 'INPUT') && word.type === 'submit');
      var said = word.innerText || word.value || word.textContent || '';
      return primary && visible(word) && /sign\s*in|log\s*in/i.test(said);
    });
    for (var j = 0; j < words.length; j++) {
      var word = words[j];
      if (!visible(word) || (signingIn && word.tagName === 'BUTTON' && word.type !== 'submit')) continue;
      var said = word.innerText || word.value || word.textContent || '';
      if (/sign\s*up|register|create\s*(an?\s*)?(account|password)|reset\s*(your\s*)?password|change\s*(your\s*)?password/i.test(said)) return true;
    }
    return false;
  }
  function automatic(box, both) {
    if (!box || !visible(box) || box.disabled || box.readOnly || box.value) return false;
    var scope = formOf(box) || component(box);
    if (freshPassword(scope)) return false;
    if (!both) {
      // An email box alone is also a newsletter or a checkout. A name
      // step must identify itself before an account goes in on its own.
      var hinted = (box.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('username') >= 0 ||
        /(^|\/)(sign.?in|log.?in|auth|session)(\/|$)/i.test(location.pathname);
      var actions = boxesIn(scope, 'button, input[type="submit"], [role="button"], h1, h2, h3');
      for (var j = 0; !hinted && j < actions.length; j++) {
        var said = actions[j].innerText || actions[j].value || actions[j].textContent || '';
        if (/sign\s*in|log\s*in/i.test(said)) hinted = true;
      }
      if (!hinted) return false;
    }
    var inputs = boxesIn(scope, 'input, textarea, select'), names = 0;
    for (var i = 0; i < inputs.length; i++) {
      var input = inputs[i], kind = (input.type || 'text').toLowerCase();
      if (!visible(input) || input.disabled || input.readOnly) continue;
      if (['text', 'email', 'tel', 'number', 'url', 'textarea', 'select-one', 'select-multiple'].indexOf(kind) >= 0) names++;
    }
    if (names > 1) return false;
    // A filled password can be beside an empty name box; it is still
    // something the person typed, and must never be replaced. A yes or a
    // no, never the name itself: Yab reads anything but true as no, and a
    // name already in the form (Google's password step) came out as the
    // name, so that step never filled by itself.
    return !both || !!(!both.pass.value && !both.pass.disabled && !both.pass.readOnly &&
      (!both.user || both.user.value || (!both.user.disabled && !both.user.readOnly)));
  }

  function put(box, value) {
    if (!box) return;
    var setter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value'
    );
    if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
    box.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    box.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  }

  // What was typed by hand and not yet sent, box by box, and boxes
  // ticked and choices made in a form the same way. A page whose boxes
  // still hold it is not put to sleep: waking it couldn't bring that
  // back. A box emptied by sending, a chat's composer, no longer
  // counts, and neither does a search box.
  var typed = [];
  document.addEventListener('input', function (e) {
    picked = null;
    if (!e.isTrusted) return;
    report();
    var el = e.composedPath ? e.composedPath()[0] : e.target;
    if (!el || typed.indexOf(el) >= 0) return;
    typed.push(el);
    if (typed.length > 40) typed.shift();
  }, true);
  // Said to the browser as it changes, a moment after typing stops or
  // something is sent, because a page that later stops answering can't
  // be asked (Stuck.swift). Only a change is said.
  var drafted = false, telling = null;
  function report() {
    if (framed) return;
    clearTimeout(telling);
    telling = setTimeout(function () {
      var now = unsaved();
      if (now === drafted) return;
      drafted = now;
      window.webkit.messageHandlers.yabForms.postMessage({ kind: 'draft', on: now });
    }, 1000);
  }
  document.addEventListener('submit', report, true);
  document.addEventListener('keydown', function (e) { if (e.key === 'Enter' && drafted) report(); }, true);
  document.addEventListener('click', function () { if (drafted) report(); }, true);
  // The option a one-choice menu starts on: the last one the page
  // marked, or with none marked, the first that can be picked (none,
  // in a list box that shows several).
  function first(el) {
    var start = -1;
    for (var i = 0; i < el.options.length; i++) {
      if (el.options[i].defaultSelected) start = i;
    }
    if (start >= 0 || el.size > 1) return start;
    for (var k = 0; k < el.options.length; k++) {
      if (!el.options[k].disabled) return k;
    }
    return -1;
  }
  // A box or a menu counts only in a form not yet sent. Outside one it
  // is a switch that saves itself or a sort order, and a page drawn by
  // a script never moves its default along with it: counted, that tab
  // would stay awake for good.
  var sent = typeof WeakSet === 'function' ? new WeakSet() : null;
  document.addEventListener('submit', function (e) {
    if (sent && e.target && e.target.tagName === 'FORM') sent.add(e.target);
  }, true);
  function pending(el) {
    return !!el.form && !(sent && sent.has(el.form));
  }
  function unsaved() {
    for (var i = 0; i < typed.length; i++) {
      var el = typed[i];
      if (!el.isConnected) continue;
      var tag = (el.tagName || '').toLowerCase();
      if (tag === 'textarea') {
        if (el.value.trim() && el.value !== el.defaultValue) return true;
      } else if (tag === 'select') {
        if (!pending(el)) continue;
        if (el.multiple) {
          for (var j = 0; j < el.options.length; j++) {
            if (el.options[j].selected !== el.options[j].defaultSelected) return true;
          }
        } else if (el.selectedIndex !== first(el)) {
          return true;
        }
      } else if (tag === 'input') {
        var kind = (el.type || 'text').toLowerCase();
        // A box ticked or a choice made, away from what the page
        // started with. A radio's group is one choice: the one picked
        // is where it moved, and a pick taken back counts no more.
        if (kind === 'checkbox' || kind === 'radio') {
          if (pending(el) && el.checked !== el.defaultChecked) return true;
          continue;
        }
        if (['text', 'email', 'url', 'tel', 'number'].indexOf(kind) < 0) continue;
        if (el.value.trim() && el.value !== el.defaultValue) return true;
      } else if (el.isContentEditable) {
        if ((el.textContent || '').trim()) return true;
      }
    }
    return false;
  }

  window.__yabForms = {
    unsaved: unsaved,
    isCodeField: function (el) { return !!codeRow(el); },
    codeFill: function (expectedDocument, expectedField, code, fill, source) {
      if (autoDocument !== expectedDocument || !lastCode || !lastCode.isConnected) return false;
      var row = codeRow(lastCode);
      if (!row || fieldIdentity(row[0], null) !== expectedField || row.some(function (b) { return b.value || b.disabled || b.readOnly || !seen(b); })) return false;
      var request = codeRequest(row);
      if (request.source && request.source !== (source || 'mail')) return false;
      // A delayed authenticator result belongs to the field still focused,
      // checked here too because its focus relay may still be in flight.
      if (source === 'key') {
        var active = inside(document.activeElement);
        // The system authentication sheet can blur the page to its body.
        // lastCode is cleared by any other editable field; all document,
        // identity, emptiness and request checks still apply here.
        if (active !== document.body && active !== document.documentElement && row.indexOf(active) < 0) return false;
      }
      if (request.digits && request.digits !== code.length) return false;
      if (!/^[A-Za-z0-9]{4,10}$/.test(code)) return false;
      if (row.length > 1 && row.length !== code.length) return false;
      if (row.length === 1 && row[0].maxLength > 0 && code.length > row[0].maxLength) return false;
      if (!fill) return true;
      var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      row.forEach(function (box, i) {
        box.focus();
        var value = row.length === 1 ? code : code[i];
        setter.call(box, value);
        box.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
      });
      return row.map(function (b) { return b.value; }).join('') === code;
    },
    // Keep the exact nodes and values before authentication; only an
    // opaque ticket goes to the browser, never these page values.
    pick: function (expectedDocument, expectedField) {
      picked = null;
      var box = lastSignIn, active = inside(document.activeElement);
      if (autoDocument !== expectedDocument || !box || !box.isConnected || !seen(box) || box.disabled || box.readOnly) return null;
      if (active !== box && active !== document.body && active !== document.documentElement) return null;
      var both = pair(box);
      if ((!both && !lone(box)) || fieldIdentity(box, both) !== expectedField) return null;
      picked = { ticket: autoDocument + ':' + (++nextPick), box: box, href: location.href,
        name: fieldState(both ? both.user : box), pass: fieldState(both && both.pass) };
      return picked.ticket;
    },
    fillPicked: function (user, password, ticket) {
      var choice = picked;
      // An older response must not consume a newer account selection.
      if (!choice || choice.ticket !== ticket) return false;
      picked = null;
      if (choice.href !== location.href) return false;
      var box = choice.box, active = inside(document.activeElement);
      if (active !== box && active !== document.body && active !== document.documentElement) return false;
      if (!seen(box) || box.disabled || box.readOnly || !unchanged(choice.name) || !unchanged(choice.pass)) return false;
      var both = pair(box);
      if (choice.pass) {
        if (!both || both.pass !== choice.pass.box || both.user !== (choice.name && choice.name.box)) return false;
        if (!seen(both.pass) || both.pass.disabled || both.pass.readOnly) return false;
        if (both.user && user && both.user.value !== user && (!both.user.value || seen(both.user))) {
          if (both.user.disabled || both.user.readOnly) return false;
          put(both.user, user);
        }
        put(both.pass, password);
      } else {
        if (both || lone(box) !== box) return false;
        put(box, user);
      }
      return true;
    },
    autoFill: function (user, password, expectedDocument, expectedField) {
      if (autoDocument !== expectedDocument) return false;
      var both = pair(), el = inside(document.activeElement);
      var box = both && (el === both.user || el === both.pass) ? el : lone(el);
      if (!automatic(box, both) || fieldIdentity(box, both) !== expectedField) return false;
      // The account can have changed while Touch ID was on screen.
      var account = both ? ((both.user && both.user.value) || pageAccount(both.pass)) : '';
      if (account && account.trim().toLowerCase() !== user.trim().toLowerCase()) return false;
      if (both) {
        if (both.user && !both.user.value) put(both.user, user);
        put(both.pass, password);
      } else {
        put(box, user);
      }
      return true;
    },
    fill: function (user, password) {
      var both = pair();
      if (!both) {
        // The name step: the name now, the password on the next page.
        var name = lone(inside(document.activeElement));
        if (!name) return false;
        put(name, user);
        return true;
      }
      // An account picked is the whole name: a few letters typed to find
      // it, or another name in the box, are replaced. A box the page filled
      // and keeps out of sight (Google's) is the page's own.
      if (both.user && user && both.user.value !== user && (!both.user.value || seen(both.user))) put(both.user, user);
      put(both.pass, password);
      return true;
    },
    // One of the person's addresses into the box the caret is in, and
    // nothing else: no password goes with it.
    email: function (address) {
      var el = inside(document.activeElement);
      if (!el || !editable(el) || (el.type || '').toLowerCase() === 'password') return false;
      put(el, address);
      return true;
    },
    // A password made by Yab, into every empty password box of the form
    // the caret is in: a sign-up's box and the one that repeats it.
    generated: function (password) {
      var both = pair();
      if (!both) return false;
      var scope = formOf(both.pass) || component(both.pass);
      var boxes = boxesIn(scope, 'input[type="password"]'), n = 0;
      for (var i = 0; i < boxes.length; i++) {
        var r = boxes[i].getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0 || boxes[i].value || boxes[i].disabled || boxes[i].readOnly || partial(boxes[i])) continue;
        put(boxes[i], password);
        n++;
      }
      return n > 0;
    },
    // Whether there is still a sign-in on the page. Asked after a
    // password went out, to tell a sign-in that took from one refused.
    hasPassword: function () {
      // Swift rechecks 1.5 seconds after "settled". Retain the submitted
      // scope after its observer stops, so an unrelated login cannot veto
      // the save, and a form restored after a rejection still can.
      if (lastSubmitted && Date.now() - lastSubmitted.at < 45000)
        return submittedPassword(lastSubmitted);
      lastSubmitted = null;
      return !!pair();
    }
  };

  // Read the submitted form before its handler can remove or empty it.
  // Swift keeps the offer pending until navigation or a settled sign-in.
  function sending(anchor) {
    var both = pair(anchor);
    if (!both) return null;
    var pass = chosen(both.pass);
    if (!pass.value) return null;
    var form = formOf(pass);
    return { user: both.user ? both.user.value : '', password: pass.value,
      action: form && form.getAttribute('action') ? form.action : '', anchor: pass };
  }

  // `held`: what the boxes held as a button was pressed, for a page that
  // empties them or takes the form away in its own click handler, before
  // its fetch goes out, which is before this hears the click.
  function offer(held, anchor) {
    var now = sending(anchor) || (held && held.password ? held : null);
    if (!now) {
      if (pair() || !named || !named.isConnected || !named.value) return;
      window.webkit.messageHandlers.yabForms.postMessage({
        kind: 'name', user: named.value
      });
      return;
    }
    window.webkit.messageHandlers.yabForms.postMessage({
      kind: 'submit',
      user: now.user,
      password: now.password,
      action: now.action || ''
    });
    watchSubmitted(now.anchor);
  }

  // The password that is being kept, which on a form with more than one
  // box is not the first: changing a password asks for the current one
  // first, and that one is already in the keychain. The box that says
  // it takes a new password, or else the last one filled in.
  function chosen(first) {
    var scope = formOf(first) || component(first);
    var boxes = boxesIn(scope, 'input[type="password"]'), filled = [];
    for (var i = 0; i < boxes.length; i++) {
      var r = boxes[i].getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && boxes[i].value && !partial(boxes[i])) filled.push(boxes[i]);
    }
    for (var j = 0; j < filled.length; j++) {
      var auto = (filled[j].getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
      if (auto.indexOf('new-password') >= 0) return filled[j];
    }
    return filled.length ? filled[filled.length - 1] : first;
  }

  document.addEventListener('submit', function (e) { offer(null, e.target); }, true);
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter') return;
    var both = pair();
    var el = inside(document.activeElement);
    if (both ? (el === both.pass || el === both.user) : (named && el === named)) offer(null);
  }, true);
  // Plenty of sign-in buttons aren't in a form and never fire submit.
  document.addEventListener('click', function (e) {
    var path = e.composedPath ? e.composedPath() : [e.target];
    var button = path.find(function (el) {
      return el.matches && el.matches('button, input[type="submit"], input[type="image"], [role="button"]');
    });
    if (button && !/reset/i.test(button.type || '')) {
      var words = [button.textContent, button.value, button.getAttribute('aria-label')].join(' ');
      if (/cancel|back|close|show|hide|forgot/i.test(words)) return;
      var submits = button.form && /^(submit|image)$/i.test(button.type || '');
      if (!submits && !/sign\s*in|log\s*in|sign\s*up|register|create.*(?:account|password)|continue|next|submit|(?:change|reset|save).*password|confirm|verify/i.test(words)) return;
      var anchor = button.form || button;
      var held = sending(anchor);
      if (held) watchSubmitted(held.anchor);
      setTimeout(function () { offer(held, anchor); }, 0);
    }
  }, true);

  var told = false;
  function tell(anchor) {
    if (framed || told || !pair(anchor)) return;
    told = true;
    window.webkit.messageHandlers.yabForms.postMessage({ kind: 'form' });
  }
  // One native load query. Dynamic forms announce themselves on focus;
  // a feed changing elsewhere never triggers form discovery.
  var initialPassword = document.querySelector('input[type="password"]');
  if (initialPassword) tell(initialPassword);

  var submitted = null, lastSubmitted = null;
  function submittedScope(state) {
    if (state.scope.isConnected) return state.scope;
    var replacement = state.id && state.root.getElementById ? state.root.getElementById(state.id)
      : state.parent && state.parent.children[state.index];
    return replacement && replacement.tagName === state.scope.tagName ? replacement : state.scope;
  }
  function submittedPassword(state) {
    var scope = submittedScope(state);
    if (!scope.isConnected) return false;
    if (!state.single) return !!pair(state.anchor, scope);
    // Direct children of body have no smaller form subtree. Track the
    // submitted password itself instead of observing/querying the feed.
    if (!scope.matches('input[type="password"]') || partial(scope)) return false;
    var r = scope.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function stopSubmitted() {
    if (!submitted) return;
    submitted.observers.forEach(function (o) { o.disconnect(); });
    clearTimeout(submitted.timer);
    submitted = null;
  }
  function watchSubmitted(anchor, captured) {
    if (!anchor) return;
    stopSubmitted();
    var scope = formOf(anchor) || component(anchor);
    // No document-wide observer, even for a formless sign-in.
    var single = scope === document || scope === document.body || scope === document.documentElement;
    if (single) scope = anchor;
    var state = captured || { anchor: anchor, scope: scope, root: scope.getRootNode(),
      single: single,
      id: scope.id, parent: scope.parentElement,
      index: scope.parentElement ? Array.prototype.indexOf.call(scope.parentElement.children, scope) : -1,
      at: Date.now() };
    submitted = lastSubmitted = state;
    scope = state.scope;
    state.observers = []; state.timer = null; state.until = Date.now() + 10000; state.gone = 0;
    function check() {
      if (submitted !== state) return;
      clearTimeout(state.timer);
      var both = submittedPassword(state);
      if (!both) {
        if (!state.gone) state.gone = Date.now();
        if (Date.now() - state.gone >= 400) {
          stopSubmitted(); told = false;
          window.webkit.messageHandlers.yabForms.postMessage({ kind: 'settled' });
          return;
        }
      } else state.gone = 0;
      if (Date.now() >= state.until) { stopSubmitted(); return; }
      // Also notices the entire form being detached, without observing its
      // parent (which could be the whole feed). Ends after ten seconds.
      state.timer = setTimeout(check, 200);
    }
    var roots = [scope];
    boxesIn(scope, 'input').forEach(function (box) {
      var root = box.getRootNode();
      if (root.host && roots.indexOf(root) < 0) roots.push(root);
    });
    roots.forEach(function (root) {
      var observer = new MutationObserver(function (records) {
        if (records.some(function (r) {
          if (r.type === 'attributes') return r.target.matches('input, select, textarea, form');
          return Array.from(r.addedNodes).concat(Array.from(r.removedNodes)).some(function (n) {
            return n.nodeType === 1 && (n.matches('input, select, textarea, form') || n.contains(anchor));
          });
        })) { clearTimeout(state.timer); state.timer = setTimeout(check, 0); }
      });
      observer.observe(root, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['type', 'hidden', 'style', 'class'] });
      state.observers.push(observer);
    });
    state.timer = setTimeout(check, 200);
  }
  window.addEventListener('pagehide', stopSubmitted);

  // Whether the caret is somewhere on the page that takes typing.
  //
  // The browser gives Tab to its own row of tabs, which is right until you
  // are filling something in: plenty of fields offer a completion you take
  // with Tab, and stealing the key there would make them unusable.
  function editable(el) {
    el = inside(el);
    if (!el) return false;
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'textarea') return true;
    if (el.isContentEditable === true) return true;
    if (el.getAttribute && el.getAttribute('role') === 'textbox') return true;
    // A document that types in a frame of its own: Google Docs keeps
    // the caret there, and the frame counts as where the typing is.
    if (tag === 'iframe') {
      try { return editable(el.contentDocument && el.contentDocument.activeElement); }
      catch (e) { return false; }
    }
    if (tag !== 'input') return false;
    var kind = (el.type || 'text').toLowerCase();
    return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
            'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
  }

  // The element the caret is really in: a box inside a component's
  // shadow root (Reddit's, a design system's) leaves the page's
  // activeElement at the component around it.
  function inside(el) {
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el;
  }

  // A box that asks for a code a site sent: said so by its page, or
  // by its name or label, or a row of one-digit boxes. What it
  // answers is the boxes the code goes in, a row's whole width.
  var codeWords = /otp|totp|2fa|mfa|passcode|one.?time|verification|verify|security.?code|auth.?code|two.?factor|authenticat/i;
  var notCode = /zip|postal|promo|coupon|discount|gift|voucher|referral|invite|country|area|phone|card|cvc|cvv|search/i;
  function codeRow(el) {
    if (!el || (el.tagName || '').toLowerCase() !== 'input') return null;
    var kind = (el.type || 'text').toLowerCase();
    if (['text', 'tel', 'number'].indexOf(kind) < 0) return null;
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    if (el.maxLength === 1) {
      var up = el.parentElement;
      for (var i = 0; i < 3 && up; i++, up = up.parentElement) {
        var all = [].filter.call(up.querySelectorAll('input'), function (b) {
          var q = b.getBoundingClientRect(); return b.maxLength === 1 && q.width > 0 && q.height > 0;
        });
        if (all.length >= 4 && all.length <= 8) return all;
      }
    }
    var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (auto.indexOf('one-time-code') >= 0) return [el];
    if (/username|email|password/.test(auto)) return null;
    var tied = el.labels && el.labels[0] && el.labels[0].innerText;
    var said = (el.name || '') + ' ' + (el.id || '') + ' ' + (tied || nearWords(el)) + ' ' +
      (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('placeholder') || '');
    if (/zip|postal|promo|coupon|discount|gift|voucher|referral|invite|country|area|card|cvc|cvv|search/i.test(said)) return null;
    if (/verification.?code|verify.?code|authenticat|one.?time|[4-8][ -]?digit.?code|\botp\b|\btotp\b/i.test(said)) return [el];
    if (notCode.test(said)) return null;
    if (codeWords.test(said)) return [el];
    // A box called only "code", X's "Enter code" under "Enter your
    // verification code": the step around it says which code.
    if (/\bcode\b/i.test(said) && codeStep(el)) return [el];
    var numeric = el.inputMode === 'numeric' || kind === 'tel' || kind === 'number' ||
      (el.maxLength >= 4 && el.maxLength <= 8);
    if (!numeric) return null;
    if (/code|pin/i.test(said)) return [el];
    // A placeholder that is a code itself, "000000" or "123456", in a
    // box that takes as many digits.
    var shape = (el.getAttribute('placeholder') || '').replace(/[\s-]/g, '');
    return /^(\d)\1{3,7}$|^0?1234(5(6(78?)?)?)?$/.test(shape) &&
      (el.maxLength <= 0 || el.maxLength === shape.length) ? [el] : null;
  }

  // Whether the step a box is the only field of asks for a sign-in code,
  // by its heading or instructions: up from the box until another field.
  function codeStep(el) {
    for (var up = el.parentElement, n = 0; up && n < 12; up = up.parentElement, n++) {
      var others = [].some.call(up.querySelectorAll('input, textarea, select, [contenteditable="true"]'), function (b) {
        return b !== el && b.type !== 'hidden' && visible(b);
      });
      if (others) return false;
      var text = (up.innerText || '').trim();
      if (text.length > 1200) return false;
      if (/verification code|confirmation code|login code|security code|two.?factor|\b2fa\b|authenticat|code generat|one.?time/i.test(text)) return true;
      if (up.tagName === 'FORM' || up.tagName === 'MAIN' || up.tagName === 'BODY') return false;
    }
    return false;
  }

  // The words a page drew over a box without tying them to it, as a
  // label reads: what comes just before it, a few boxes up. Partiful's
  // "Verification Code" sits over a box whose only word is "000000".
  function nearWords(el) {
    for (var up = el, n = 0; up && n < 4; up = up.parentElement, n++) {
      for (var sib = up.previousElementSibling; sib; sib = sib.previousElementSibling) {
        if (sib.querySelector && sib.querySelector('input, select, textarea')) return '';
        var w = (sib.innerText || sib.textContent || '').replace(/\s+/g, ' ').trim();
        if (w) return w.length <= 80 ? w : '';
      }
    }
    return '';
  }

  // The code's delivery method and length belong to this step, not
  // just to the site. Read the label and nearby visible instructions;
  // stop at another editable field rather than borrowing its prompt.
  function codeRequest(row) {
    if (!row) return {};
    var el = row[0], count = row.length > 1 ? row.length : el.maxLength;
    var digits = row.length > 1 ? row.length : null;
    var source = null;
    var words = [(el.labels && el.labels[0] && el.labels[0].innerText || '') + ' ' + nearWords(el) + ' ' +
      (el.getAttribute('aria-label') || '')];
    (el.getAttribute('aria-describedby') || '').split(/\s+/).forEach(function (id) {
      var hint = document.getElementById(id);
      if (hint && visible(hint)) words.unshift(hint.innerText || '');
    });
    for (var up = el.parentElement, n = 0; up && n < 12; up = up.parentElement, n++) {
      var others = [].some.call(up.querySelectorAll('input, textarea, select, [contenteditable="true"]'), function (b) {
        return row.indexOf(b) < 0 && b.type !== 'hidden' && visible(b);
      });
      if (others) break;
      var text = (up.innerText || '').trim();
      if (text.length > 1200) break;
      words.push(text);
      if (up.tagName === 'FORM' || up.tagName === 'MAIN' || up.tagName === 'BODY') break;
    }
    words.forEach(function (text) {
      if (!source) {
        var sms = /\bsms\b|text message|texted/i.test(text);
        var mail = /\be-?mail\b/i.test(text);
        var key = /authenticator|authentication app|code generat|\btotp\b/i.test(text);
        if (Number(sms) + Number(mail) + Number(key) === 1) source = sms ? 'text' : mail ? 'mail' : 'key';
      }
      if (!digits) {
        var size = text.match(/\b([4-8])[ -]?(?:digit|character)/i);
        if (size) digits = Number(size[1]);
      }
    });
    if (!digits) {
      var pattern = (el.getAttribute('pattern') || '').match(/\{([4-8])\}/);
      var shape = (el.getAttribute('placeholder') || '').replace(/[\s-]/g, '');
      if (pattern) digits = Number(pattern[1]);
      else if (/^[0-9]{4,8}$/.test(shape)) digits = shape.length;
      else if (count >= 4 && count <= 8) digits = count;
    }
    return { source: source, digits: digits };
  }

  // AppKit sees one native text client for the whole web page. Give it
  // the focused box's meaning so it does not guess that an empty email
  // box wants the last code from Messages.
  function inputContent(el, row, box) {
    el = inside(el);
    if (!el || !editable(el)) return 'none';
    if (row) return 'code';
    var kind = (el.type || '').toLowerCase();
    var auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
    if (auto.indexOf('new-password') >= 0) return 'new-password';
    if (kind === 'password') return 'password';
    if (kind === 'email' || auto.indexOf('email') >= 0) return 'email';
    if (auto.indexOf('username') >= 0 || box) return 'username';
    if (kind === 'tel' || auto.some(function (word) { return /^tel($|-)/.test(word); })) return 'phone';
    if (kind === 'url' || auto.indexOf('url') >= 0) return 'url';
    return 'text';
  }

  // A trusted entry after the person opened Passwords is enough to
  // remember which account uses it. No code leaves the page in this
  // message; yab only learns that a code was entered.
  if (!framed) document.addEventListener('input', function (e) {
    if (!e.isTrusted) return;
    var row = codeRow(e.target);
    if (!row || row.some(function (box) { return !box.value; })) return;
    var value = row.map(function (box) { return box.value; }).join('').replace(/\D/g, '');
    if (value.length >= 4 && value.length <= 8)
      window.webkit.messageHandlers.yabForms.postMessage({ kind: 'codeEntered' });
  }, true);

  function pageAccount(pass) {
    var scope = formOf(pass) || document;
    var kept = boxesIn(scope, 'input[autocomplete~="username"]')[0];
    if (kept && kept.value) return kept.value;
    var chip = document.querySelector('[data-email]');
    if (chip && chip.getAttribute('data-email')) return chip.getAttribute('data-email');
    chip = document.querySelector('[data-profile-identifier], #profileIdentifier');
    var words = chip ? (chip.textContent || '').trim() : '';
    return words.indexOf('@') > 0 && words.length < 120 ? words : '';
  }

  __YAB_GROUND__
  // Read once for each box: the caret comes back here every frame of
  // a scroll.
  var grounded = null, dark = null;
  // What was said last, and where the caret was then: a scroll's frame
  // that would say the same again says nothing.
  var said = null, saidAt = undefined, hung = true, saidBox = false;
  function caret(scrolled) {
    var el = inside(document.activeElement);
    learn(el);
    var both = el && el.matches && el.matches('input') ? pair(el) : null;
    if (both) tell(el);
    var rect = null;
    var typed = '';
    var secret = false, empty = true;
    var box = both && el && (el === both.user || el === both.pass) ? el : lone(el);
    if (picked && el !== picked.box && editable(el)) picked = null;
    if (box || editable(el)) lastSignIn = box;
    // A frame speaks of its sign-in boxes alone, and of the caret
    // leaving one.
    if (framed && !box && !saidBox) return;
    saidBox = !!box;
    if (box && !both) named = box;
    // What is in a name box so far, to narrow the list by. A password
    // box narrows nothing.
    if (box && (!both || box === both.user)) typed = box.value || '';
    if (box) { secret = !!both && box === both.pass; empty = !box.value; }
    var fresh = secret && freshPassword(formOf(box) || component(box));
    // Who a password step is for, as the page itself says it: the name
    // kept in the form for password managers (Google's hidden
    // identifier), or the account chip it shows over the box.
    var account = '';
    if (secret) account = (both.user && both.user.value) || pageAccount(both.pass);
    if (box) {
      var r = box.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
      if (box !== grounded) { grounded = box; dark = yabGround(box); }
    }
    var row = box || framed ? null : codeRow(el);
    var request = codeRequest(row);
    if (row) {
      // Let macOS Passwords recognize a code field even when the site
      // omitted or disabled its standard AutoFill hint.
      if (row.length === 1 && row[0].getAttribute('autocomplete') !== 'one-time-code')
        row[0].setAttribute('autocomplete', 'one-time-code');
      var a = row[0].getBoundingClientRect(), z = row[row.length - 1].getBoundingClientRect();
      rect = { x: a.left, y: Math.min(a.top, z.top), w: z.right - a.left, h: Math.max(a.bottom, z.bottom) - Math.min(a.top, z.top) };
      empty = !row.some(function (b) { return b.value; });
      if (el !== grounded) { grounded = el; dark = yabGround(el); }
    }
    // What the box the caret is in is, for the address field's
    // places: a password box, a box that takes lines, and what it is
    // called, so the field can say where ↩ will put something.
    var at = inside(el);
    var input = at && at.tagName && at.tagName.toLowerCase() === 'input';
    var label = '';
    if (at && editable(at)) {
      label = (at.labels && at.labels[0] && at.labels[0].innerText) || (at.getAttribute && (at.getAttribute('aria-label') || at.getAttribute('placeholder'))) || at.name || '';
      label = String(label).replace(/\s+/g, ' ').trim().slice(0, 32);
    }
    var message = {
      kind: 'focus',
      typing: editable(at),
      rect: rect,
      dark: rect ? dark : null,
      typed: typed,
      secret: secret,
      fresh: fresh,
      empty: empty,
      automatic: !!box && automatic(box, both),
      document: autoDocument,
      field: box ? fieldIdentity(box, both) : row ? fieldIdentity(row[0], null) : '',
      account: account,
      password: !!input && (at.type || '').toLowerCase() === 'password',
      lines: !!at && !input && editable(at),
      label: label,
      signin: !!box,
      webauthn: webauthn(box),
      webauthnForm: webauthnForm(box),
      content: inputContent(at, row, box),
      code: !!row,
      codeSource: request.source || '',
      codeDigits: request.digits || 0,
      // The caret in a frame of the page: that frame says the rest.
      inFrame: !framed && !!at && /^i?frame$/i.test(at.tagName || '')
    };
    // Where this frame is on the page is asked of the page, by these.
    if (framed) {
      message.href = location.href;
      message.vw = document.documentElement.clientWidth;
      message.vh = document.documentElement.clientHeight;
    }
    if (row && empty) lastCode = row[0];
    else if (row || editable(at)) lastCode = null;
    saidAt = el;
    hung = !!rect;
    var words = JSON.stringify(message);
    if (scrolled === true && words === said) return;
    said = words;
    window.webkit.messageHandlers.yabForms.postMessage(message);
  }

  if (framed) {
    var early = window.__yabFormsSoon && window.__yabFormsSoon.take();
    document.addEventListener('focusin', caret, true);
    document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
    document.addEventListener('input', function () { if (saidBox) caret(); }, true);
    caret();
    if (early) watchSubmitted(early.anchor, early.state);
    return;
  }

  // The box moves when the page scrolls or the window changes size, and
  // whatever hangs from it has to move too. Once a frame at most.
  var moving = false;
  function moved(scrolled) {
    if (moving) return;
    moving = true;
    requestAnimationFrame(function () { moving = false; caret(scrolled === true); });
  }
  window.addEventListener('scroll', function () {
    // Nothing hangs from a box and the caret is where it was: a scroll
    // moves nothing of ours. Asked on every frame of every scroll, it
    // looked for the page's password boxes, read their places, and told
    // Yab the same nothing, which wrote the tab again each time.
    if (!hung && inside(document.activeElement) === saidAt) return;
    moved(true);
  }, true);
  // Page zoom also resizes the viewport. Deduplicate when nothing hangs
  // from the caret; a focused box still needs its CSS rectangle rescaled
  // by the browser, even when that rectangle itself has not changed.
  window.addEventListener('resize', function () { moved(!hung); });
  // A code suggestion must leave on the first keystroke, even when
  // WebKit is not drawing frames (an occluded or covered window).
  document.addEventListener('input', function (e) {
    var row = codeRow(e.target);
    if (row) {
      caret();
      var text = row.map(function (b) { return b.value; }).join('').replace(/[\s-]/g, '');
      var request = codeRequest(row);
      if (/^[A-Za-z0-9]{4,10}$/.test(text) && (!request.digits || text.length === request.digits)) {
        window.webkit.messageHandlers.yabForms.postMessage({ kind: 'codeAccepted', text: text });
      }
    } else moved();
  }, true);

  // A paste counts only after the page accepted it in a verification field.
  document.addEventListener('paste', function (e) {
    var row = codeRow(inside(e.target));
    if (!row || !e.clipboardData) return;
    var text = e.clipboardData.getData('text/plain').replace(/[\s-]/g, '');
    if (!/^[A-Za-z0-9]{4,10}$/.test(text)) return;
    setTimeout(function () {
      var actual = row.map(function (b) { return b.value; }).join('').replace(/[\s-]/g, '');
      if (actual === text) window.webkit.messageHandlers.yabForms.postMessage({ kind: 'codePasted', text: text });
    }, 0);
  }, true);

  // A box in a dialog that is still opening is measured mid-animation
  // (X's sign-in grows into place): the list hung half again as wide as
  // the box. Measured again as the page's animations end, and a beat
  // after the caret came, for one with none to hear.
  function settled() { if (hung) moved(true); }
  document.addEventListener('transitionend', settled, true);
  document.addEventListener('animationend', settled, true);
  document.addEventListener('focusin', function () {
    setTimeout(settled, 250);
    setTimeout(settled, 600);
  }, true);
  document.addEventListener('focusin', caret, true);
  document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
  document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
  caret();
})();
