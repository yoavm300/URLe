// Dashboard interactions: copy-to-clipboard + AJAX delete with inline feedback.
// Progressive enhancement — the server-rendered forms still work without JS.
document.addEventListener('DOMContentLoaded', function () {
    var feedback = document.getElementById('js-feedback');
    var feedbackTimer;

    function showFeedback(message, type) {
        if (!feedback) {
            return;
        }
        feedback.textContent = message;
        feedback.className = 'feedback ' + (type || 'info') + ' show';
        clearTimeout(feedbackTimer);
        feedbackTimer = setTimeout(function () {
            feedback.classList.remove('show');
        }, 2500);
    }

    function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        // Fallback for non-secure contexts (e.g. plain http://localhost is fine,
        // but some browsers gate the async API behind HTTPS).
        return new Promise(function (resolve, reject) {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            var ok = false;
            try {
                ok = document.execCommand('copy');
            } catch (e) {
                ok = false;
            }
            document.body.removeChild(ta);
            ok ? resolve() : reject(new Error('copy failed'));
        });
    }

    // Copy-to-clipboard buttons
    document.querySelectorAll('[data-copy]').forEach(function (btn) {
        btn.addEventListener('click', function () {
            copyText(btn.getAttribute('data-copy')).then(function () {
                showFeedback('Short link copied to clipboard.', 'success');
            }).catch(function () {
                showFeedback('Could not copy link.', 'danger');
            });
        });
    });

    // AJAX delete — intercept the POST form, hit the JSON DELETE endpoint.
    document.querySelectorAll('form[data-ajax-delete]').forEach(function (form) {
        form.addEventListener('submit', function (e) {
            e.preventDefault();
            var id = form.getAttribute('data-url-id');
            var row = form.closest('tr');
            var btn = form.querySelector('button');
            if (btn) {
                btn.disabled = true;
            }

            fetch('/url/' + id, {
                method: 'DELETE',
                headers: { 'X-Requested-With': 'XMLHttpRequest' }
            }).then(function (res) {
                if (!res.ok) {
                    throw new Error('request failed');
                }
                return res.json();
            }).then(function () {
                if (row) {
                    row.remove();
                }
                showFeedback('URL deleted.', 'info');
                refreshEmptyState();
            }).catch(function () {
                if (btn) {
                    btn.disabled = false;
                }
                showFeedback('Could not delete URL.', 'danger');
            });
        });
    });

    // When the last row is removed, reload so the server renders the empty state.
    function refreshEmptyState() {
        var tbody = document.querySelector('.url-table tbody');
        if (tbody && tbody.children.length === 0) {
            window.location.reload();
        }
    }
});
