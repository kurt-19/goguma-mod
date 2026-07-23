# Connecting to a server

When Goguma is launched for the first time, it asks for a server, nickname and
(optionally) a password.

The server field accepts hostnames, such as "irc.libera.chat". This should
cover most use-cases. Also supported are:

- IPv4 and IPv6 addresses.
- `<host>:<port>`, for servers using non-standard ports.
- `irc+insecure://<host>:<port>`, for insecure cleartext connections. Warning,
  only use for local development.

Once the server field is filled in, Goguma will query the server capabilities.
Some servers don't support SASL authentication, in which case the password
field will get hidden. Some servers require SASL authentication, in which case
the password field won't be optional anymore.

If the server uses a TLS certificate which cannot be verified, Goguma will
prompt the user to accept/reject the certificate. If the certificate is
accepted, Goguma will proceed and pin the certificate (in other words, "Trust
On First Use": Goguma will only accept this specific certificate when
connecting to the server). By design, Goguma will refuse to connect and will
not prompt again if the server certificate changes. This feature should be used
sparingly: blindly accepting unverified certificates is a security risk.
