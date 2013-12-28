#lang racket

(require "constraints.rkt" "package.rkt" "mk-structs.rkt" "variables.rkt" "errors.rkt" 
         "infs.rkt" "helpers.rkt" "operators.rkt" "events.rkt" "substitution.rkt" "lex.rkt")
(require (for-syntax racket syntax/parse racket/syntax racket/match racket/function
                     "syntax-classes.rkt")
         "syntax-classes.rkt"
         "triggers.rkt")
(require syntax/parse racket/syntax)

(require (rename-in (only-in racket filter) [filter ls:filter]))

(provide send-event
         fresh-aux
         fresh
         sum
         update-package
         add-constraint
         remove-constraint
         add-association
         enforce
         reify
         reifyc
         default-reify)

(define (sum lsct)
  (for/fold ([out succeed]) ([ct lsct])
    (conj ct out)))

;; defines a macro to create new unconstrained variables
(define-syntax fresh-aux
  (syntax-rules ()
    [(_ constructor (x ...) g g* ...)
     (let ([x (constructor (gensym 'x))] ...)
       (conj 
        (send-event (enter-scope-event x)) ...
        g g* ...
        (send-event (leave-scope-event x)) ...))]))

;; miniKanren's "fresh" defined in terms of fresh-aux over vars
(define-syntax-rule (fresh (x ...) g g* ...)
  (fresh-aux var (x ...) g g* ...))

;; Event -> ConstraintTransformer
;; runs all the constraints on the event in the store, 
;; accumulating all their new events and then recurring
(define (send-event new-e)
  (lambda@ (a [s c q t e-orig])
    (cond
     ;; is the thing we are trying to send empty? if so, why send it
     [(empty-event? new-e) a]
     ;; if e-orig is empty we can run!
     [(empty-event? e-orig)
      (define store c)
      (define running-e (start-running new-e))
      (define send-to-all (conj send-to-running send-to-store solidify-event))
      (bindm (make-a s c q t running-e) send-to-all)]
     ;; if we are already running, don't try to run again. just add
     ;; the event we are trying to send to the waiting events
     [(running-event? e-orig)
      (make-a s c q t (compose-events new-e e-orig))]
     [else (error 'send-event "found unsent event: ~a\n" e-orig)])))

;; ConstraintTransformer
;; sends each running event to all other running events
(define send-to-running
  (lambda@ (a [s c q t e])
    (match-define (running-event r w) e)
    (cond
     [(composite-event? r)
      (bindm a (send-to-comp-event r))]
     [else a])))

;; Event -> ConstraintTransformer
(define (send-to-comp-event r)
  (match-define (composite-event es) r)
  (define (loop pre post)
    (match post
      [(list) succeed]
      [(cons e rest)
       (conj (send-to-other-events e (append pre rest))
             (loop (cons e pre) rest))]))
  (loop (list) es))

;; Event [List-of Event] -> ConstraintTransformer
(define (send-to-other-events e es)
  (define addcs 
    (filter add-constraint-event/internal? 
            (composite-event es))) ;; TODO: hack
  (define maybe-response
    (match-lambda
      [(add-constraint-event/internal rator rands)
       (define reaction (-constraint-reaction rator))
       (cond
        ;; is our kind of constraint generally interested in anything
        ;; inside of the event we have?
        [(reaction e)
         => ;; Response -> ConstraintTransformer
         (lambda (response)
           (run-response response rator (list rands)))]
        ;; if not, just use the accumulator
        [else succeed])]))
  (sum (map maybe-response addcs)))

;; ConstraintTransformer
(define solidify-event
  (lambda@ (a [s c q t e])
    (match-define (running-event r w) e)
    (define old-r
      (cond
       [(composite-event? r)
        (composite-event-es r)]
       [else (list r)]))
    (define new-r (solidify old-r w))
    (bindm (make-a s c q t (empty-event))
           (conj (sum (map solidify-atomic-event old-r))
                 (send-event new-r)))))

;; Event ConstraintStore -> ConstraintTransformer
(define send-to-store
  (lambda@ (a [s c q t e])
    (define store c)
    (define ct
      (for/fold 
        ([ct succeed]) 
        ([(rator rands*) store])
        (lambda@ (a [s c q t e])
          (match-define (running-event r w) e)
          (define reaction (-constraint-reaction rator))
          (cond
           ;; is our kind of constraint generally interested in anything
           ;; inside of the event we have?
           [(reaction r)
            => ;; Response -> ConstraintTransformer
            (lambda (response)
              (bindm a (conj (run-response response rator rands*) ct)))]
           ;; if not, just use the accumulator
           [else (bindm a ct)]))))
    (bindm a ct)))

;; Response Rator [List-of Rands] -> ConstraintTransformer
(define (run-response r rator rands*)
  (for/fold ([ct succeed]) ([rands rands*])
    (lambda@ (a [s c q t e]) ;; we need the e?
      (define removing-self?
        (match-lambda
          [(remove-constraint-event/internal rator^ rands^)
           (eq? rands rands^)]
          [else #f]))
      (define answer
        (cond
         ;; are we witnessing ourself be removed
         [(findf removing-self? e) ct]
         ;; is our constraint actually subscribed to our event?
         [(apply-response r rands a)
          => (match-lambda 
               [(list (cons tr* ct*) ...)
                ;; run-response-ct performs the changes the constraint
                ;; would like to see given the trigger.  our goal is to
                ;; capture what events it causes and chain them after the
                ;; trigger.
                (conj (for/fold 
                        ([answer succeed])
                        ([tr (reverse tr*)] [real-response (reverse ct*)])
                        (cond
                         ;; if the event we are trying to subscribe to still exists in the
                         ;; current event, then we run the responses from our rands
                         [(findf (curry eq? tr) e)
                          (conj (chain tr)
                                (remove-constraint (oc rator rands))
                                real-response
                                (unchain removing-self? answer))]
                         [else answer]))
                      ct)]
               [else (error 'run-response "~a" else)])]
         [else ct]))
      (bindm a answer))))

(define (chain tr)
  (lambda@ (a [s c q t e])
    (match-define (running-event r w) e)
    (define new-e 
      (running-event r (build-chain-event tr w (empty-event))))
    (make-a s c q t new-e)))

(define (unchain rs? ct)
  (lambda@ (a [s c q t e])
    (match-define (running-event r w) e)
    (match w
      [(build-chain-event tr old new)
       (define new-e (running-event r (apply-chain w)))
       (define new-a (make-a s c q t new-e))
       (cond
        [(findf rs? new) new-a]
        [else (bindm new-a ct)])]
      [else a])))

(define (apply-response r rands a)
  ((apply r rands) a))

(define (add-association x v)
  (let ([x (if (var? x) x v)]
        [v (if (var? x) v x)])
    (send-event (add-association-event x v))))

(define (add-constraint an-oc)
  (match-define (oc rator rands) an-oc)
  (send-event ((-constraint-add rator) rator rands)))

(define update-s
  (case-lambda
   [(u v)
    (lambda@ (a [s c q t e])
      (make-a (ext-s u v s) c q t e))]
   [(p) 
    (lambda@ (a [s c q t e])
      (make-a (ext-s* p s) c q t e))]))

(define (update-c new-oc)
  (lambda@ (a [s c q t e])
    (make-a s (ext-c new-oc c) q t e)))

(define (remove-from-c an-oc)
  (lambda@ (a [s c q t e])
    (make-a s (remq-c an-oc c) q t e)))

(define (remove-constraint an-oc)
  (match-define (oc rator rands) an-oc)
  (send-event ((-constraint-rem rator) rator rands)))

(define (enforce x)
  (lambda@ (a [s c q t e])
    a
    #;
    (let ([x (filter*/var? (walk x (substitution-s s)))])
      (bindm a (conj (add-event (enforce-event x)) send-event)))))

(define (reify x)
  (lambda@ (a [s c q t e])
    (define v (walk* x s c e))
    (define r (reify-s v empty-s))
    (define v^ (reify-term v r))
    (define answer
      (cond
       [(null? r) v^]
       [else (reify-constraints v^ r c)]))
    answer))

;; reifies the substitution, returning the reified substitution
(define (reify-s v^ s)
  (define v (walk v^ s))
  (cond
   [(var? v) 
    `((,v . ,(reify-n v (size-s s))) . ,s)]
   [(mk-struct? v) 
    (define (k a d)
      (reify-s d (reify-s a s)))
    (recur v k)]
   [else s]))

(define (reify-n cvar n)
  (string->symbol (format "~a.~a" (cvar->str cvar) (number->string n))))

(define (reifyc x)
  (lambda@ (a [s c q t e])
    ;; get all of the variables mentioned in the constraint store and
    ;; make a reified substitution for them
    (define v (walk* (filter*/var? (hash->list c)) s c e))
    (define r (reify-s v empty-s))
    
    ;; then sort and return a reified version of all constraints
    (sort-store (run-reify-fns v r c))))

(define (reify-constraints v r store)
  (define store^ (run-reify-fns v r store))
  (cond
   [(null? store^) v] 
   [#t `(,v : . ,(sort-store store^))]
   [else `(,v . ,(sort-store store^))]))

;; sorts the constraint store by lex<=
(define (sort-store ocs) (sort ocs lex<= #:key car))

(define (run-reify-fns v r store)
  (hash->list
   (for*/fold
    ([h (hasheq)])
    ([(rator rands*) store]
     #:when (-constraint-reifyfn rator)
     [rands rands*])
    (define-values (sym ans)
      ((apply (-constraint-reifyfn rator) rands) v r))
    (cond
     [(any/var? ans) h]
     [else
      (define updatefn (curry insert-in-lex-order ans))
      (hash-update h sym updatefn '())]))))

;; given a new substitution and constraint store, adds the prefixes of
;; each to the existing substitution and constraint store. the
;; constraints in c-prefix still need to run
(define (update-package s^ c^)
  (lambda@ (a [s c q t e])
    (define s-prefix (prefix-s s s^))
    (define c-prefix (prefix-c c c^))
    (define add-event (add-substitution-prefix-event s-prefix))
    (bindm a (conj (send-event add-event) (sum c-prefix)))))

;; Event -> ConstraintTransformer
(define/match (solidify-atomic-event e)
  [((add-association-event u v)) (update-s u v)]
  [((add-substitution-prefix-event p)) (update-s p)]
  [((add-constraint-event/internal rator rands))
   (update-c (oc rator rands))]
  [((remove-constraint-event/internal rator rands)) 
   (remove-from-c (oc rator rands))]
  [((empty-event)) succeed]
  [(e) succeed])

(define (default-reify sym . args)
  (define reified-rands
    (cond
     [(null? args) args]
     [(null? (cdr args)) (car args)]
     [else args]))
  (values sym reified-rands))


