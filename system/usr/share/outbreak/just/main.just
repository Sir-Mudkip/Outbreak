set allow-duplicate-recipes
set ignore-comments

_default:
    @ujust --list --list-heading $'Available commands:\n' --list-prefix $' - '

import "/usr/share/outbreak/just/updates.just"
import "/usr/share/outbreak/just/system.just"
