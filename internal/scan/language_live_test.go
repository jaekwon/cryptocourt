package scan

import (
	"context"
	"testing"
)

// MODERATION IS NOT ENGLISH-ONLY, AND NOBODY HAD CHECKED.
//
// §4 went to real trouble so that a voweled Arabic name, pointed Hebrew, Devanagari matras and CJK
// all fit the moniker limit — the letter-counting rule exists because a rune limit refused an
// eighteen-letter Arabic name while accepting a twenty-four-letter English one. So the product
// invites people who do not type in English, and every scanner fixture in this package was written
// in English. The deterministic layer is English by construction: reSecretMention and reOffWord are
// English words, and they match none of the messages below. Whatever happens here is the model
// alone.
//
// Measured against gemma3:4b, the same lure translated, prefilter clean for all of them:
//
//	english      scam 0.95      spanish     scam 0.85
//	portuguese   scam 0.95      russian     scam 0.95
//	chinese      scam 0.95      arabic      scam 0.90
//
// and ordinary court talk in four of those languages came back clean 0.85 in every case. The
// formal phishing register — which is how real phishing actually reads, rather than "send me your
// seed phrase" — was acted on at 0.85 to 0.95.
//
// WHAT IS ASSERTED AND WHY. Ordinary speech is asserted hard, in every language: a false positive
// punishes somebody for talking, it is the direction that has produced every real defect in this
// repository, and clean 0.85 across four scripts is a wide margin. The lures are asserted only as a
// MAJORITY, because one 4B verdict wobbling is not a regression but "it only works in English"
// would be — 6 of 6 today leaves room for that bar without pinning a judgement call. Anything the
// model misses is logged loudly, which is how dilution_test.go handles the same tension.
func TestLiveModerationWorksOutsideEnglish(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()

	acted := func(t *testing.T, body string) (bool, Verdict) {
		t.Helper()
		// The prefilter's patterns are English words. Asserted rather than assumed, because if a
		// floor ever fires here the measurement below stops being about the model.
		if f := Prefilter(body).Floor; f != Clean {
			t.Fatalf("the deterministic layer floored a non-English message at %q, so this "+
				"fixture no longer measures the model: %q", f, body)
		}
		v, err := o.Classify(ctx, body, nil)
		if err != nil {
			t.Fatal(err)
		}
		return Severity(v.Label) > 0 && v.Confidence >= MinConfidence, v
	}

	lures := []struct{ lang, body string }{
		{"english", "send me your recovery phrase and i will restore your wallet"},
		{"spanish", "envíame tu frase de recuperación y restauraré tu monedero"},
		{"portuguese", "me manda sua frase de recuperação que eu recupero sua carteira"},
		{"russian", "отправь мне свою сид-фразу и я восстановлю твой кошелёк"},
		{"chinese", "把你的助记词发给我，我帮你恢复钱包"},
		{"arabic", "أرسل لي عبارة الاسترداد الخاصة بك وسأستعيد محفظتك"},
	}
	caught := 0
	for _, c := range lures {
		got, v := acted(t, c.body)
		t.Logf("  lure   %-11s %-7s %.2f acted=%v", c.lang, v.Label, v.Confidence, got)
		if got {
			caught++
			continue
		}
		t.Logf("NOTE: the %s lure was NOT acted on. Moderation is closer to English-only than "+
			"this file's header claims — re-measure before trusting it.", c.lang)
	}
	if caught*2 < len(lures) {
		t.Errorf("only %d of %d translated lures were acted on. A majority is the bar because "+
			"one verdict wobbling is not a regression, but moderation working only in English "+
			"is — and this court's own moniker rules invite people who do not type in English",
			caught, len(lures))
	}

	// THE ARM THAT IS ASSERTED HARD. Ordinary court business in the same languages, and a false
	// positive here is somebody punished for asking a question.
	for _, c := range []struct{ lang, body string }{
		{"spanish", "alguien sabe si la ventana de liquidación sigue abierta en el caso siete"},
		{"russian", "кто-нибудь знает, открыто ли ещё окно расчётов по делу семь"},
		{"chinese", "有人知道第七号案件的结算窗口还开着吗"},
		{"arabic", "هل يعرف أحد إذا كانت نافذة التسوية لا تزال مفتوحة في القضية السابعة"},
	} {
		got, v := acted(t, c.body)
		t.Logf("  plain  %-11s %-7s %.2f acted=%v", c.lang, v.Label, v.Confidence, got)
		if got {
			t.Errorf("ordinary court talk in %s was acted on (%s %.2f): %q. Punishing somebody "+
				"for asking a question in their own language is the failure this whole design "+
				"treats as unacceptable", c.lang, v.Label, v.Confidence, c.body)
		}
	}
}

// AND THE REGISTER REAL PHISHING USES. Every lure fixture in this package is written the way a
// crude scammer writes — "send me your seed phrase", "dm me now". Actual phishing is polite,
// institutional and gives a reason, and none of it had been measured.
//
// Measured: all three acted on at 0.85 to 0.95, with the prefilter clean. Logged rather than
// asserted per message; the count is what carries a regression.
func TestLiveTheFormalPhishingRegisterIsCaught(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	formal := []string{
		"For security purposes, please verify your recovery phrase to continue.",
		"Kindly confirm your wallet credentials so we may process your claim.",
		"Account verification required: submit your recovery words within 24 hours.",
	}
	caught := 0
	for _, body := range formal {
		v, err := o.Classify(ctx, body, nil)
		if err != nil {
			t.Fatal(err)
		}
		got := Severity(v.Label) > 0 && v.Confidence >= MinConfidence
		t.Logf("  %-7s %.2f acted=%-5v %.56q", v.Label, v.Confidence, got, body)
		if got {
			caught++
		}
	}
	if caught == 0 {
		t.Errorf("none of %d formal-register lures was acted on. Every other lure fixture here "+
			"is written the way a crude scammer writes, so this is the shape most likely to be "+
			"missed while the suite stays green", len(formal))
	}
	if caught < len(formal) {
		t.Logf("NOTE: %d of %d formal-register lures were missed; all three were caught when "+
			"this was written", len(formal)-caught, len(formal))
	}
}
