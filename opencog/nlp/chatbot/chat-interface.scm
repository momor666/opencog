;
; chat-interface.scm
;
; Simple scheme interface to glue together the chat-bot to the cog-server.
; 
; Linas Vepstas April 2009
;

(use-modules (ice-9 rdelim))  ; for the system call

;; Hack to flush IO except this hack doesn't work :-(
;; doesn't work because of how the SchemEval.cc handles ports ... 
(define (fflush) (force-output (car  (fdes->ports 1))))

; -----------------------------------------------------------------------
; Semantic triples processing code.
;
; The ready-for-triples-anchor is an anchor node at which sentences may
; be queued up for triples processing.  Sentences that are linked to 
; this node will eventually have triples built from them.
(define ready-for-triples-anchor (AnchorNode "# APPLY TRIPLE RULES" (stv 1 1)))

; copy-sents-to-triple-anchor -- 
; Copy a list of sentences to the input triple processing anchor
; Here, sent-list should be a list of SentenceNodes
; This is slightly tricky, because the triples anchor is expecting
; not SentenceNodes, but ParseNodes.  So for each sentence, we have
; to get the parses, and attach those.
;
(define (copy-sents-to-triple-anchor sent-list)

	;; Attach all parses of a sentence to the anchor.
	(define (attach-parses sent)
		;; Get list of parses for the sentence.
		(define (get-parses sent)
			(cog-chase-link 'ParseLink 'ParseNode sent)
		)
		;; Attach all parses of the sentence to the anchor.
		;; This must have a true/confident TV so that the pattern
		;; matcher will find and use this link.
		(for-each (lambda (x) (ListLink ready-for-triples-anchor x (stv 1 1)))
			(get-parses sent)
		)
	)
	;; Attach all parses of all sentences to the anchor.
	(for-each attach-parses sent-list)
)

; Delete sentences that were wating for triples processing
(define (delete-triple-anchor-links)
	(for-each (lambda (x) (cog-delete x))
		(cog-incoming-set ready-for-triples-anchor)
	)
)

; The result-triples-anchor anchors the results of triples processing.
(define result-triples-anchor (AnchorNode "# RESULT TRIPLES" (stv 1 1)))

; create-triples -- extract semantic triples from RelEx dependency
; parses, using the code in the nlp/triples directory.
(define (create-triples)

	(define (attach-triples triple-list)
		;; Attach all of the recently created triples to the anchor.
		;; This must have a true/confident TV so that the pattern
		;; matcher will find and use this link.
		(for-each (lambda (x) (ListLink result-triples-anchor x (stv 1 1)))
			(cog-outgoing-set triple-list) 
		)
	)

	; First, create all of the preposition phrases that we'll need.
	(for-each
		(lambda (rule)
			(cog-ad-hoc "do-implication" rule)
		)
		prep-rule-list ; this list defined by the /triples/prep-rules.txt file
	)
	(for-each
		(lambda (rule)
			(attach-triples (cog-ad-hoc "do-implication" rule))
		)
		frame-rule-list ; this list defined by the /triples/rules.txt file
	)
)

; get-new-triples -- Return a list of semantic triples that were created.
(define (get-new-triples)
	(cog-chase-link 'ListLink 'EvaluationLink result-triples-anchor)
)

; delete-result-triple-links -- delete links to result triples anchor.
(define (delete-result-triple-links)
	(for-each (lambda (x) (cog-delete x))
		(cog-incoming-set result-triples-anchor)
	)
)

; Fetch, from SQL storage, all knowledge related to the recently produced
; triples. Specifically, hunt out the WordNode's tht occur in the triples,
; and get everything we know about them (by getting everything that has 
; that word-node in it's outgoing set.)
(define (fetch-related-triples)

	; Given a handle h to some EvaluationLink, walk it down and pull
	; in any related WordNode expressions.
	(define (fetch-word h)
		(if (eq? 'WordInstanceNode (cog-type h))
			(cog-ad-hoc "fetch-incoming-set" (word-inst-get-lemma h))
		)
		(for-each fetch-word (cog-outgoing-set h))
	)

	; Pull in related stuff for every triple that was created.
	(for-each fetch-word (get-new-triples))
)

; -----------------------------------------------------------------------
; say-id-english -- process user input from chatbot.
; args are: user nick from the IRC channel, and the text that the user entered.
;
; XXX FIXME: use of display here is no good, since nothing is written till
; processing is done.  We need to replace this by incremenntal processing
; and/or handle i/o on a distinct thread.
;
(define query-soln-anchor (AnchorNode "# QUERY SOLUTION"))
(define (say-id-english nick txt)

	; Define a super-dooper cheesy way of getting the answer to the question
	; Right now, its looks for WordNode's attached, via ListLink, to 
	; an AnchorNode called "# QUERY SOLUTION". This is of course very wrong,
	; and is just a placeholder for now.
	(define (get-simple-answer)
		(cog-chase-link 'ListLink 'WordNode query-soln-anchor)
	)
	(define (delete-simple-answer)
		(for-each (lambda (x) (cog-delete x)) (cog-incoming-set query-soln-anchor))
	)
	(define (do-prt-soln soln-list)
		;; display *all* items in the list.
		(define (show-item wlist)
			(if (not (null? wlist))
				(let ()
					(display (cog-name (car wlist)))
					(display " ")
					(show-item (cdr wlist))
				)
			)
		)
		(display "The answer to your question is: ")
		(show-item soln-list)
	)

	(define (prt-soln soln-list)
		(if (not (null? soln-list))
			(do-prt-soln soln-list)
		)
	)

	; Declare some state variables for the imperative style to follow
	(define sents '())
	(define is-question #f)

	(display "Hello ")
	(display nick)
	(display ", parsing ...\n")
	(fflush)

	; Parse the input, send it to the question processor
	(relex-parse txt)

	(set! sents (get-new-parsed-sentences))

	; Hmm. Seems like sents is never null, unless there's a 
	; programmig error in Relex.  Otherwise, it always returns 
	; something, even if the input was non-sense.
	(if (null? sents)
		(let ()
			(display nick)
			(display ", you said: \"")
			(display txt)
			(display "\" but I couldn't parse that.")
			(newline)
		)
		(set! is-question (cog-ad-hoc "question" (car sents)))
	)

	;; was a question asked?
	(if is-question 
		(let ()
			(display nick)
			(display ", you asked a question: ")
			(display txt)
			(newline)
			(prt-soln (get-simple-answer))
		)
		(let ()
			(display nick)
			(display ", you made a statement: ")
			(display txt)
			(newline)
		)
	)

	; Run the triples processing.
	(copy-sents-to-triple-anchor (get-new-parsed-sentences))
	(create-triples)
	(delete-triple-anchor-links)

	; If a question was asked, and  the previous attempt to answer the
	; question failed, try again with pattern matching on the triples.
	(if (and is-question (null? (get-simple-answer)))
		(let ((trips (get-new-triples)))
			(display "There was no simple answer; attempting triples search\n")
			(fetch-related-triples)
			(if (not (null? trips))
				(cog-ad-hoc "triple-question" (car (get-new-triples)))
			)
			(if (not (null? (get-simple-answer)))
				(prt-soln (get-simple-answer))
				(display "No answer was found to your question.")
			)
		)
	)

	; Delete list of triples, so they don't interfere with the next question.
	(delete-result-triple-links)

	; Delete  the list of solutions, so that we don't accidentally
	; replay it when the next question is asked.
	(delete-simple-answer)

	; cleanup -- these sentences are not new any more
	(delete-new-parsed-sent-links)
	""
)

