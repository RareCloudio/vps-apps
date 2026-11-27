"""Add "on-link: true" to the IPv6 default routes of one netplan file that need it.

Usage: python3 -I netplan-onlink.py <netplan-file> <output-file>

A route needs it when all of these hold:
  - its "to" is ::/0 or default, and its "via" is an IPv6 address that is not link-local;
  - it has no "on-link" key at all (a key that is there, true or false, is the owner's choice);
  - its interface has at least one static IPv6 address in its own "addresses" (not the DNS servers
    under "nameservers"), and the gateway is inside none of their prefixes. Without a static IPv6
    address the prefix is not known, so the route is left alone.

The file is read as lines, never loaded and dumped as YAML: the line "on-link: true" is inserted
after the route's "via" line, at the same indentation, and every other byte stays as it was. The
reader follows the block style netplan files are written in (mappings and lists by indentation,
flow lists of scalars such as "addresses: [a, b]"). A route written in flow style is left alone.

When a route needs the flag, the new content goes to the output file and one line
"<device> <gateway> [<keys>]" is printed for each such route (the device is the interface's
set-name when it has one, else its netplan id). <keys> lists, comma-separated, the LIVE_KEYS the
route has: a plain live route for it would not be the route netplan sets up. When nothing needs
the flag, nothing is printed and the output file is not written. Exit 0 either way; 1 when the
file cannot be read or the output cannot be written. Python standard library only.
"""

import ipaddress
import sys

ANY6 = ipaddress.IPv6Network("::/0")
# Route keys that make the route more than a plain default route on the main table.
LIVE_KEYS = ("from", "metric", "scope", "table", "type")


class Entry:
    """One open block: a mapping key or a list item, at its column."""

    def __init__(self, col, kind, name=None):
        self.col = col
        self.kind = kind
        self.name = name


class Iface:
    def __init__(self, ident):
        self.ident = ident
        self.set_name = None
        self.addresses = []
        self.routes = {}


def strip_comment(text):
    """The text without a trailing comment: a # at the start or after a blank, outside quotes."""
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"" and (i == 0 or text[i - 1] in " \t[{,:-"):
            quote = ch
        elif ch == "#" and (i == 0 or text[i - 1] in " \t"):
            return text[:i].rstrip()
    return text.rstrip()


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def split_key(text):
    """(key, value) when the text is "key:" or "key: value" (value "" for the first), else None.

    As in YAML, only a colon followed by a blank or the end of the line ends a key, so an IPv6
    address such as 2a06:a880::1/64 is a plain value.
    """
    if text[:1] in ("{", "["):
        return None
    if text[:1] in ("'", '"'):
        end = text.find(text[0], 1)
        if end < 0:
            return None
        rest = text[end + 1:].lstrip()
        if rest == ":" or rest.startswith((": ", ":\t")):
            return text[1:end], rest[1:].strip()
        return None
    for i, ch in enumerate(text):
        if ch == ":" and (i + 1 == len(text) or text[i + 1] in " \t"):
            return text[:i].strip(), text[i + 1:].strip()
    return None


def flow_items(value):
    """The scalars of a flow list "[a, b]", or [] when the value is not one."""
    if not (value.startswith("[") and value.endswith("]")):
        return []
    return [unquote(v) for v in value[1:-1].split(",") if v.strip()]


def names(stack):
    """The open blocks as a tuple: key names, and None for each list item."""
    return tuple(e.name if e.kind == "key" else None for e in stack)


def parse(lines):
    """The interfaces of the file, by (device type, id)."""
    stack = []
    ifaces = {}

    def iface(path):
        key = (path[1], path[2])
        if key not in ifaces:
            ifaces[key] = Iface(path[2])
        return ifaces[key]

    for index, raw in enumerate(lines):
        text = strip_comment(raw.rstrip("\r\n"))
        body = text.lstrip(" ")
        if not body or body in ("---", "..."):
            continue
        col = len(text) - len(body)
        on_item_line = False
        if body == "-" or body.startswith("- "):
            # A list item closes deeper blocks and the previous item at its column, but not the key
            # that owns the list, which may sit at the same column ("routes:" then "- to: ...").
            while stack and (stack[-1].col > col or (stack[-1].col == col and stack[-1].kind == "item")):
                stack.pop()
            stack.append(Entry(col, "item", index))
            rest = body[1:]
            body = rest.lstrip(" ")
            if not body:
                continue
            col += 1 + len(rest) - len(body)
            on_item_line = True
        kv = split_key(body)
        if kv is None:
            path = names(stack)
            if (on_item_line and len(path) == 5 and path[0] == "network" and None not in path[:3]
                    and path[3] == "addresses"):
                iface(path).addresses.append(unquote(body))
            continue
        key, value = kv
        while stack and stack[-1].col >= col:
            stack.pop()
        path = names(stack) + (key,)
        stack.append(Entry(col, "key", key))
        if len(path) < 4 or path[0] != "network" or None in path[:3]:
            continue
        if len(path) == 4 and key == "addresses":
            iface(path).addresses.extend(flow_items(value))
        elif len(path) == 4 and key == "set-name":
            iface(path).set_name = unquote(value)
        elif len(path) == 6 and path[3] == "addresses" and path[4] is None and on_item_line:
            # An address with options: - "2001:db8::1/64": {lifetime: 0}
            iface(path).addresses.append(key)
        elif len(path) == 6 and path[3] == "routes" and path[4] is None:
            route = iface(path).routes.setdefault(stack[-2].name, {})
            route[key] = unquote(value)
            if key == "via":
                route["@line"], route["@col"] = index, col
    return ifaces


def is_default6(to):
    if to == "default":
        return True
    try:
        return ipaddress.ip_network(to, strict=False) == ANY6
    except ValueError:
        return False


def fixes(ifaces):
    """(via line index, via column, device, gateway, LIVE_KEYS present) per route that needs on-link."""
    out = []
    for iface in ifaces.values():
        nets = []
        for address in iface.addresses:
            try:
                ip = ipaddress.ip_interface(address)
            except ValueError:
                continue
            if ip.version == 6:
                nets.append(ip.network)
        if not nets:
            continue
        for route in iface.routes.values():
            if "on-link" in route or "@line" not in route or not is_default6(route.get("to", "")):
                continue
            try:
                gw = ipaddress.IPv6Address(route["via"])
            except ValueError:
                continue
            if gw.is_link_local or gw.is_multicast or gw.is_unspecified or any(gw in n for n in nets):
                continue
            keys = ",".join(k for k in LIVE_KEYS if k in route)
            out.append((route["@line"], route["@col"], iface.set_name or iface.ident, route["via"], keys))
    return out


def split_lines(text):
    """The lines of the text with their line ends; the last one may have none."""
    parts = text.split("\n")
    lines = [p + "\n" for p in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines


def run(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: netplan-onlink.py <netplan-file> <output-file>\n")
        return 1
    try:
        with open(argv[1], encoding="utf-8", errors="surrogateescape", newline="") as f:
            lines = split_lines(f.read())
    except OSError as e:
        sys.stderr.write("netplan-onlink: %s\n" % e)
        return 1
    found = fixes(parse(lines))
    if not found:
        return 0
    for line, col, _, _, _ in sorted(found, reverse=True):
        via = lines[line]
        body = via.rstrip("\r\n")
        end = via[len(body):]
        if end:
            lines.insert(line + 1, " " * col + "on-link: true" + end)
        else:
            lines[line] = body + "\n"
            lines.insert(line + 1, " " * col + "on-link: true")
    try:
        with open(argv[2], "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write("".join(lines))
    except OSError as e:
        sys.stderr.write("netplan-onlink: %s\n" % e)
        return 1
    seen = []
    for _, _, device, gw, keys in found:
        if (device, gw, keys) not in seen:
            seen.append((device, gw, keys))
            print(" ".join(w for w in (device, gw, keys) if w))
    return 0


def main(argv):
    """run(), with any unexpected error printed as its type alone, exit 1: an exception's message
    can quote the netplan file (a wifi password, a key), and the caller logs this output."""
    try:
        return run(argv)
    except Exception as e:  # every unexpected error ends here, as its type alone
        sys.stderr.write("netplan-onlink: %s\n" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
