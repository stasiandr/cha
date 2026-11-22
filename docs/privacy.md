# cha and your Google data

cha is a personal browser for macOS. When you connect Google Calendar from
its menu, cha asks Google for read-only access to your calendar events
(`calendar.events.readonly`) and uses it only to show your next meeting in
the sidebar and to remind you a minute before it starts.

- Events are fetched straight from Google to your Mac and kept in memory;
  nothing is sent anywhere else, and there is no cha server.
- The sign-in token is stored on your Mac only, in cha's folder
  (`~/Library/Application Support/cha/google-token.json`, readable only by
  your user account).
- Disconnect Google Calendar in the cha menu to delete the token; you can
  also revoke access at https://myaccount.google.com/permissions.

cha's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.
