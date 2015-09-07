#lang racket

(require (only-in "lang-struct.rkt"
                  bind-name bind-exp make-bind mtch-bindings bindings-table))
(require "error.rkt")
(require "binding-forms-definitions.rkt")

;; == public interface ==

(provide freshen α-equal? safe-subst)


;; == parameters 

;; The binding forms in the current language
(define bf-table (make-parameter "binding-forms table not defined"))
;; Necessary to avoid a circular import
(define pattern-matcher (make-parameter "pattern matcher not defined"))
;; Sometimes we want fresh names, sometimes we want canonical names
(define name-generator (make-parameter "name generator not defined"))

;; Because we duplicate binders to implement #:...bind, we dedupe them here
(define anti-duplication-table (make-parameter "anti-duplication table not defined"))
;; For α-equivalence testing, we walk the whole term at once.
(define all-the-way-down? (make-parameter "all-the-way-downness not defined"))

;; == implementation of public interface ==

;; The first step is to set up the parameters. Then, each of these functions
;; uses `rec-freshen` in some way.

;; freshen : (listof (list compiled-pattern bspec)) 
;; (compiled-pattern redex-val -> (union #f mtch)) redex-val -> redex-val
(define (freshen language-bf-table match-pattern redex-val)
  (parameterize ([bf-table language-bf-table]
                 [pattern-matcher match-pattern]
                 [name-generator gensym]
                 [anti-duplication-table (make-hasheqv)]
                 [all-the-way-down? #f])
                (first (rec-freshen redex-val #f #t #f))))

(define (α-equal? language-bf-table match-pattern redex-val-lhs redex-val-rhs)
  (cond
   ;; short-circuit on some easy cases:
   [(eq? redex-val-lhs redex-val-rhs) #t]
   [(and (symbol? redex-val-lhs) (symbol? redex-val-rhs)) (symbol=? redex-val-lhs redex-val-rhs)]
   [(or (xor (symbol? redex-val-lhs)
             (symbol? redex-val-rhs))
        (xor (list? redex-val-lhs)
             (list? redex-val-rhs))) #f]

   [else 
    (define canonical-name-list '())
    
    (parameterize 
     ([bf-table language-bf-table]
      [pattern-matcher match-pattern]
      [anti-duplication-table (make-hasheqv)]
      [all-the-way-down? #t])

     (define canonical-lhs 
       (parameterize
        ([name-generator ;; record the names generated in order
          (λ (orig-name)
             (define new-name (gensym orig-name))
             (set! canonical-name-list (cons new-name canonical-name-list))
             new-name)])
        
        (first (rec-freshen redex-val-lhs #f #t #f))))

     (set! canonical-name-list (reverse canonical-name-list)) ;; we generated it back-to-front


     (define canonical-rhs 
       (parameterize
        ([name-generator ;; re-use the generated names... until we run out 
          (λ (orig-name)
             (if (empty? canonical-name-list)
                 (gensym orig-name) ;; At this point, we know the answer will be #f
                 (match-let ([`(,new-name . ,remaining-canonical-names) canonical-name-list])
                   (set! canonical-name-list remaining-canonical-names)
                   new-name)))])
        
        (first (rec-freshen redex-val-rhs #f #t #f))))
    
     (equal? canonical-lhs canonical-rhs))]))

;; Perform a capture-avoiding substitution
(define (safe-subst language-bf-table match-pattern redex-val redex-val-old-var redex-val-new-val)
  (parameterize
   ([bf-table language-bf-table]
    [pattern-matcher match-pattern]
    [name-generator gensym]
    [anti-duplication-table (make-hasheqv)]
    [all-the-way-down? #t])

   (let loop [(v (first (rec-freshen redex-val #f #t #f)))]
     (cond
      [(list? v) (map loop v)]
      [(eq? redex-val-old-var v) redex-val-new-val]
      [else v]))))

;; == pattern-dispatch ==

;; This takes a plain redex-val (and the bf-table parameter) and figures out what
;; binding form (if any) applies to it. It also tears `redex-val` apart into a redex match,
;; in the case where a binding form does apply.

;; `dispatch` is used by `freshen-rec`, `rename-references`, and `exported-binders`.


;; Dispatch to `redex-val`'s appropriate binding spec, if there is one. Otherwise, fall
;; back to the other function.
;; dispatch : redex-val (red-match bspec -> X) (redex-val -> X) -> X 
(define (dispatch redex-val fn nospec-fn)
  (match redex-val 
    [(? list?)
     (let loop ((bf-table (bf-table)))
       (match bf-table
              [`((,compiled-pat ,bspec) . ,rest)
               (define match-res ((pattern-matcher) compiled-pat redex-val))
               (match match-res
                 [#f (loop rest)]
                 ;; "bindings" is what the rest of Redex calls what we call "red-match"
                 [`(,m) (fn (splay-all-...binds (bindings-table (mtch-bindings m)) bspec)
                            bspec)])]
              [`() (nospec-fn redex-val)]))]
    ;; `value-with-spec` is an internal-only "pre-matched" form
    [(value-with-spec match spec) (fn match spec)] ;; (we know it's been splayed)
    [_ (nospec-fn redex-val)]))

;; (As an optimization, we might want to, at compile time, precompute a map from
;;  export-names to the driving names, so we don't have to traverse the bspec an 
;;  additional time)




;; `splay-all-...binds` restructures a `redex-match` so that each repeat of the `#:...bind`
;; is a separate binding object.
;; splay-all-...binds : red-match bspec -> red-match
(define (splay-all-...binds red-match bspec)
  (let loop ([body (bspec-body bspec)] [red-match red-match])
    (match body
      [(import/internal sb _) (loop sb red-match)]
      [(.../internal sb _) (loop sb red-match)]
      [(...bind/internal name drivers bspec)
       (splay-...bind red-match drivers name bspec)]
      [`(,head . ,tail) (loop head (loop tail red-match))]
      [atom red-match])))


;; unsplay : redex-val -> redex-val
(define (unsplay redex-val)
  (define (unsplay-rec v)
    (match v
           [`() `()]
           ;; (This matches up with the `...bind/internal` case in `surface-bspec->pat&bspec`)
           [`(,first-part ,second-part)
            `(,first-part . ,(unsplay-rec second-part))]))

  (match redex-val
    [(value-with-spec red-match bs)
     (unsplay-rec (red-match->redex-val red-match bs))]
    [normal-value (unsplay-rec normal-value)]))


;; == Redex match stuff ==
;; Lookup into Redex matches, with fallback
(define-syntax-rule (rm-lookup-or name red-match otherwise)
  (let loop ([red-match red-match])
    (cond
     [(empty? red-match) otherwise]
     [(symbol=? (bind-name (first red-match)) name) (bind-exp (first red-match))]
     [else (loop (rest red-match))])))

;; ... with error
(define (rm-lookup name red-match)
  (rm-lookup-or name red-match 
                (redex-error #f "name `~s` not found in redex match: ~s" name red-match)))

(define (rm-lookup-as-list name red-match) `(,(rm-lookup name red-match)))

;; == ... stuff ==
;; push-down-symbols : (listof bind) -> (listof (listof bind))
;; undo a layer of `...` in a list of binds
(define (push-down-symbols binds)
  (map (λ (b) 
          (map (λ (exp) (make-bind (bind-name b) exp))
               (bind-exp b)))
       binds))

(module+ test
  (require rackunit)
  (define mb make-bind)
  (check-equal? (push-down-symbols `(,(mb 'x '(1 2 3)) ,(mb 'y '(4 5 6))))
                `((,(mb 'x 1) ,(mb 'x 2) ,(mb 'x 3))
                  (,(mb 'y 4) ,(mb 'y 5) ,(mb 'y 6)))))

;; pass-... : match (listof symbol) (∪ #f natural-number) -> (listof match)
;; Turns a match into a list of matches, each corresponding to one step of 
;; transcribing a `...`. `driving-names` indicates which names are inside the
;; `...` and therefore need to be walked through.

;; If no driving names are applicable, `repeat-count` should be a number
(define (pass-... red-match driving-names [repeat-count #f])
  ;; here "bind" has the *Redex* meaning of a pair of a name and the value
  ;; bound to that name by `redex-match`
  (define-values (driven-binds undriven-binds)
    (partition (λ (b) (member (bind-name b) driving-names)) red-match))

  (define pushed-down-driven (push-down-symbols driven-binds))

  (if (empty? pushed-down-driven)
      (build-list repeat-count (λ (idx) undriven-binds)) ;; driven-binds will be empty
      (apply map
             (cons (λ driven-binds (append driven-binds undriven-binds))
                   pushed-down-driven))))

(module+ test
  (check-equal? 
   (pass-... `(,(mb 'x `(1 2 3)) ,(mb 'y `(1 2 3)) ,(mb 'z `(1 2 3))) `(x y))
   `((,(mb 'x 1) ,(mb 'y 1) ,(mb 'z `(1 2 3)))
     (,(mb 'x 2) ,(mb 'y 2) ,(mb 'z `(1 2 3)))
     (,(mb 'x 3) ,(mb 'y 3) ,(mb 'z `(1 2 3))))))

;; Turn a `...bind` matched as a list into a chain of independent Redex matches
;; This should be used right after creating `red-match` on each `...bind` in the pattern
(define (splay-...bind red-match driving-names name-of-tail bspec-of-tail)
  (define passed-matches (pass-... red-match driving-names #f))
  
  (define (make-tail-match p-m)
    (if (empty? p-m)
        `()
        (value-with-spec `(,(make-bind name-of-tail 
                                       (make-tail-match (cdr p-m)))
                           . ,(car p-m))
                         bspec-of-tail)))

  ;; make it referrable-to in the Redex match
  `(,(make-bind name-of-tail (make-tail-match passed-matches)) 
    . ,red-match))

(module+ test

  ;; Example:
  ;; (let* ((a 1)
  ;;        (b (+ 1 a))
  ;;        (c (+ 1 a b)))
  ;;   (+ a b c))
  (check-equal?
   (splay-...bind `(,(mb 'xv `(a b c)) ,(mb 'ev `(1 (+ 1 a) (+ 1 a b))) ,(mb 'ebody `(+ a b c)))
                     `(xv ev)
                     `clauses
                     `clauses-bspec)
   `(,(mb 'clauses 
          (value-with-spec 
           `(,(mb 'clauses 
                  (value-with-spec
                   `(,(mb 'clauses 
                          (value-with-spec
                           `(,(mb 'clauses `())
                             ,(mb 'xv `c)
                             ,(mb 'ev `(+ 1 a b))
                             ,(mb 'ebody `(+ a b c)))
                           `clauses-bspec))
                     ,(mb 'xv `b)
                     ,(mb 'ev `(+ 1 a))
                     ,(mb 'ebody `(+ a b c)))
                   `clauses-bspec))
             ,(mb 'xv `a)
             ,(mb 'ev `1)
             ,(mb 'ebody `(+ a b c)))
           `clauses-bspec))
     ,(mb 'xv `(a b c))
     ,(mb 'ev `(1 (+ 1 a) (+ 1 a b)))
     ,(mb 'ebody `(+ a b c))))

  
  )

;; == Beta stuff ==

;; interp-beta : beta match (X X -> X) (symbol match -> X) X -> X 
;; Fold over the matched values referred to by `beta`.
(define (interp-beta beta red-match combine nt-case empty-case)
  ;; doesn't allow `red-match` to change
  (define (interp-beta* beta)
    (match beta
      [(rib/internal betas) (interp-betas betas)]
      [(shadow/internal betas) (interp-betas betas)]
      [nt-ref (nt-case nt-ref red-match)]))

  (define (interp-betas betas)
    (match betas
      [`(,(.../internal beta driving-names) . ,rest-betas)
       (combine 
        (foldr combine empty-case 
               (map (λ (sub-red-match) 
                       (interp-beta beta sub-red-match combine nt-case empty-case))
                    (pass-... red-match driving-names)))
        (interp-betas rest-betas))]
      [`(,beta . ,rest-betas)
       (combine (interp-beta* beta) (interp-betas rest-betas))]
      [`() empty-case]))

  (interp-beta* beta))


(module+ test
  (check-equal? (interp-beta (shadow/internal `(a b ,(rib/internal `(d e))))
                             `(,(mb 'a 1) ,(mb 'b 2) ,(mb 'd 3) ,(mb 'e 4) ,(mb 'z 9))
                             append rm-lookup-as-list '())
                `(1 2 3 4))

  (check-equal? (interp-beta (shadow/internal `(a ,(.../internal `b `(b))
                                                  ,(.../internal `z `(z))
                                                  ,(.../internal (rib/internal `(c d)) `(c d))))
                             `(,(mb `a 1) ,(mb `b `(2 3 4)) ,(mb `c `(5 7)) ,(mb `d `(6 8))
                               ,(mb `z `(99)))
                             append rm-lookup-as-list `())
                `(1 2 3 4 99 5 6 7 8)))

(define (interp-beta-as-set beta red-match)
  (interp-beta beta red-match append rm-lookup-as-list '()))

(define (interp-beta-as-fs-subst beta freshened-subterms) 
  (interp-beta beta freshened-subterms append ;; gives us override semantics
               (lambda (name f-s) (second (rm-lookup name f-s))) '()))
   

;; == Reference renaming ==
 
;; apply-subst : symbol subst -> symbol
(define (apply-subst name σ)
  (match (assoc name σ)
         [`(,_ ,new-name) new-name]
         [#f name]))

(define (rename-references-nospec redex-val σ)
  (cond
   [(list? redex-val) (map (λ (elt) (rename-references elt σ)) redex-val)]
   [(symbol? redex-val) (apply-subst redex-val σ)]
   [else redex-val]))

;; rename-references-spec : match bspec substitution -> sexp
;; `red-match` should be the output of matching the bspec's Redex pattern against
;; the input value
;; When `#:...bind` planted some `value-with-spec`s in `red-match`, this removes them,
;; since `rename-references'
(define (rename-references-spec red-match bs σ)
  (let loop [(red-match red-match) (body (bspec-body bs)) (σ σ)]
    (match body
      [(import/internal sub-body beta)
       (define newly-bound-names (append* (map exported-binders (interp-beta-as-set beta red-match))))
       (loop red-match sub-body
             (filter (match-lambda [`(,name ,_) (not (member name newly-bound-names))]) σ))]

      [`(,(.../internal sub-body driving-names) . ,body-rest)

       `(,@(map 
           (lambda (sub-red-match) (loop sub-red-match sub-body σ))
           (pass-... red-match driving-names))
         . ,(loop red-match body-rest σ))]

      [`(,(...bind/internal ...-name _ _) . ,body-rest)

       (match-define (value-with-spec val ...-bspec) (rm-lookup ...-name red-match))

       ;; (rename-references val σ) would also work
       `(,@(unsplay (rename-references-spec val ...-bspec σ))
         . ,(loop red-match body-rest σ))]

      [`(,body-first . ,body-rest)
       `(,(loop red-match body-first σ) . ,(loop red-match body-rest σ))]
      [`() `()]
      [name
       (define leaf-value (rm-lookup-or name red-match name))
       (if (and (symbol? leaf-value) (member name (bspec-ported-nts bs)))
           leaf-value ;; this atom is a binder, not a reference
           (rename-references leaf-value σ))])))


;; Utility function to undo matching
(define (red-match->redex-val red-match bs)
  (rename-references-spec red-match bs `()))

(define (rename-references redex-val σ)
  (dispatch redex-val (λ (rv b) (rename-references-spec rv b σ))
            (λ (rv) (rename-references-nospec rv σ))))

(module+ test
  (define lambda-bspec (bspec `(lambda (x) ,(import/internal `expr `x))
                              (rib/internal `()) `(x) `() `(x)
                              `((lambda 0) (x 0) (expr 0))))

  (define ieie-bspec
    (bspec `(ieie x_i x_e x_ie
                  ,(import/internal `expr_1 (shadow/internal `(x_ie x_i)))
                  ,(import/internal `expr_2 (shadow/internal `(x_i x_ie))))
           (shadow/internal `(x_i x_ie)) `(x_ie x_i) `(x_ie x_e) `(x_ie x_i x_e)
           `((x_i 0) (x_e 0) (x_ie 0) (expr_1 0) (expr_2 0))))

  (define-syntax-rule (mrm (name val) ...)
    `(,(make-bind `name `val) ...))


  ;; subterms have no binding structure this way:
  (parameterize ([bf-table `()]
                 [pattern-matcher #f])

                
    (check-equal?
     (rename-references-spec
      (mrm (lambda lambda) (x a) (expr (a b c))) lambda-bspec `((a aa) (b bb)))
     `(lambda (a) (a bb c)))

    (check-equal?
     (rename-references-spec
      (mrm (lambda lambda) (x d) (expr (a b c))) lambda-bspec `((a aa) (b bb)))
     `(lambda (d) (aa bb c)))


    (check-equal?
     (rename-references-spec
      (mrm (ieie ieie) (x_i a) (x_e b) (x_ie c)
           (expr_1 (a (b (c (d (e (f g)))))))
           (expr_2 (a (b (c (d (e (f g))))))))
      ieie-bspec
      `((a aa) (b bb) (c cc) (d dd) (e ee) (f ff)))
     `(ieie a b c
           (a (bb (c (dd (ee (ff g))))))
           (a (bb (c (dd (ee (ff g)))))))))

  
  )

;; Freshen a value that has no specification (and thus, at this level, no binding behavior).
(define (rec-freshen-nospec redex-val noop? top-level? assume-binder?)
  (if (and top-level? (not (all-the-way-down?)))
      `(,redex-val ())
      (cond
       ;; no exports
       [(list? redex-val) 
        `(,(if (all-the-way-down?)
               ;; `noop?` is true because unused exports are treated as free
               (map (λ (elt) (car (rec-freshen elt #f #t #f))) redex-val)
               redex-val) ())]
       [(and (symbol? redex-val) assume-binder?)
        (if (or noop? (and top-level? (all-the-way-down?))) 
            `(,redex-val ((,redex-val ,redex-val)))
            (redex-error 
             #f 
             (format "Internal error in freshening: a binder (~s) escaped being freshened." redex-val)))]
       [else `(,redex-val ())])))


;; freshen-subterms : ... -> (listof bind)
;; The expressions in the binds are the return values of `rec-freshen`
;; (i.e., a pair of a new value and its corresponding substitution),
;; for those subterms that are "ported" (i.e. imported or exported)
(define (freshen-subterms red-match bs noop? top-level?)
  (filter-map
   (λ (b)
     (define nt-name (bind-name b))

     (define trscr-depth (assoc nt-name (bspec-transcription-depths bs)))
     (define sub-exported? (member nt-name (bspec-exported-nts bs)))
     (define sub-ported? (not (not (member nt-name (bspec-ported-nts bs)))))

     
     ;; I had to build a Karnaugh Map to understand this, but the gist is
     ;; that, from the top level, exported subterms must be a noop 
     ;; (since their exported binders are free),
     ;; and otherwise *exported* subterms must be the same as their parents.
     ;; (since whether they are exported the same distance as the parents)
     ;; Non-exported subterms can safely be freshened, so it happens
     ;; if `all-the-way-down?` is true, but doesn't have to otherwise.
     (define sub-noop? (if top-level?
                           sub-exported?
                           (if sub-exported?
                               noop?
                               (not (all-the-way-down?)))))
     
     (and trscr-depth ;; is it transcribed at all?
          (or sub-ported? (all-the-way-down?))
          (make-bind
           nt-name
           ;; TODO: is this lookup ever important, except in the case of non-transcribed imports,
           ;; which we don't currently suport

           ;; Here, look up `b` to see if that particular bind has been freshened already (which can
           ;; only happen if the redex match has been splayed for #:...bind). If so, we are
           ;; revisiting the same binder (i.e., they both originated at the same position in the
           ;; original value), and should assign it the same name. (by "binder", we may mean "group
           ;; of binders under `...`")
           (hash-ref! 
            (anti-duplication-table) b
            (λ () ;; Not revisiting a binder
               (let handle-... ([...-depth (second trscr-depth)] [exp (bind-exp b)])
                 (if (= ...-depth 0)
                     (if (symbol? exp)
                         (let ([new-name
                                ;; Is it a binder, and should we freshen it?
                                (if (and sub-ported? (not sub-noop?)) 
                                    ((name-generator) exp) 
                                    exp)])
                           `(,new-name ((,exp ,new-name))))
                         ;; It's something more complex:
                         (rec-freshen exp sub-noop? #f sub-ported?))
                 (map (λ (sub-exp) (handle-... (- ...-depth 1) sub-exp)) exp))))))))
   red-match))


(define (rec-freshen-spec red-match bs noop? top-level?)
  (define freshened-subterms (freshen-subterms red-match bs noop? top-level?))

  (define freshened-body
    (let loop ([red-match red-match] [freshened-subterms freshened-subterms] 
               [body (bspec-body bs)])
      (match body
        ;; I thought that `rename-reference`ing this subterm of the current form was
        ;; going to be a problem: `rename-reference` doesn't have any idea about the
        ;; binding structure of a *partial* form, so it treats it naively. However!
        ;; That binding structure has already been freshened by the time this `r-r`
        ;; gets called. That means that all the names bound (at least, bound by *this*
        ;; form, but binding structure below that *will be* understood by `r-r`) have
        ;; been renamed to fresh names (relative to the domain of this renaming), and
        ;; so will be unaffected: just what we want.
        [(import/internal sub-body beta)
         (rename-references (loop red-match freshened-subterms sub-body)
                            (interp-beta-as-fs-subst beta freshened-subterms))]
        
        [`(,(.../internal sub-body driving-names) . ,body-rest)
         (define red-match-under-... (pass-... red-match driving-names))

         `(,@(map (λ (sub-red-match sub-freshened-subterms)
                    (loop sub-red-match sub-freshened-subterms sub-body))
                  red-match-under-...
                  (pass-... freshened-subterms driving-names (length red-match-under-...)))

           . ,(loop red-match freshened-subterms body-rest))]

        [`(,(...bind/internal ...-name _ _) . ,body-rest)
         `(,@(unsplay 
              (first (rm-lookup-or 
                      ...-name freshened-subterms
                      `(,(rm-lookup ...-name red-match) ()))))

           . ,(loop red-match freshened-subterms body-rest))]
        
        [`(,body-first . ,body-rest)
         `(,(loop red-match freshened-subterms body-first)
           . ,(loop red-match freshened-subterms body-rest))]
        [`() `()]
        [nt 
         (first ;; discard the substitution; we only need the freshened value
          (rm-lookup-or 
           nt freshened-subterms 
           ;; In Romeo, unused binders (i.e., exported but never imported)
           ;; are treated as bound. For Redex purposes, it's important that they be
           ;; free, so that putting things into plain lists doesn't unexpectedly bind things.
           ;; See https://github.com/paulstansifer/redex/issues/10
           `(,(rm-lookup-or nt red-match nt) ())))])))

  (define freshened-exports 
    (interp-beta-as-fs-subst (bspec-export-beta bs) freshened-subterms))

  `(,freshened-body ,freshened-exports))

;; rec-freshen : redex-value bool bool bool -> (list redex-value subst)
;; If noop? is true, don't freshen; return the input 
(define (rec-freshen redex-val n? t-l? a-b?)
  ;; assume-binder? is only relevant for atoms, which never have specs
  (dispatch redex-val (λ (rv bs) (rec-freshen-spec rv bs n? t-l?)) 
            (λ (rv) (rec-freshen-nospec rv n? t-l? a-b?)))) 



;; exported-binders : redex-value -> (list symbol)
(define (exported-binders redex-val)
  (map cadr (second ;; top-level? needs to be off, since lone binders matter!
             (dispatch redex-val (λ (rv bs) (rec-freshen-spec rv bs #t #f))
                       (λ (rv) (rec-freshen-nospec rv #t #f #t))))))

(module+ test
  (define (all-distinct? . lst)
    (equal? lst (remove-duplicates lst)))

  ;; subterms have no binding structure this way:
  (parameterize ([bf-table `()]
                 [pattern-matcher #f]
                 [name-generator gensym]
                 [anti-duplication-table (make-hasheqv)]
                 [all-the-way-down? #f])

    (check-equal?
     (rec-freshen-nospec `(a b c) #f #t #f)
     `((a b c) ()))
    
    (check-equal?
     (rec-freshen-nospec `(a b c) #f #f #f)
     `((a b c) ()))

    (check-equal?
     (rec-freshen-nospec `a #f #t #f)
     `(a ()))

    (check-match
     (rec-freshen-nospec `a #f #f #f)
     `(a ()))

    (check-match 
     (rec-freshen-spec 
      (mrm (lambda lambda) (x a) (expr (a b c)))
      lambda-bspec #f #t)
     `((lambda (,aa) (,aa b c)) ())           
     (all-distinct? aa 'a 'b 'c))))