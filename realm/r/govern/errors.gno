package govern

// govErr is this realm's error, for the kinds it owns.
//
// The engine has its own and keeps it unexported, which is right: an error type
// crossing a package boundary is a type consumers start type-asserting on, and
// what a kind returns is a message rather than a class.
type govError struct{ msg string }

func (e *govError) Error() string { return "govern: " + e.msg }

func govErr(s string) error { return &govError{s} }
