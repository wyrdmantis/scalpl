(defpackage #:scalpl.mpex
  (:nicknames #:mpex)
  (:export #:*mpex* #:mpex-agent)
  (:use #:cl #:chanl #:anaphora #:local-time
        #:split-sequence #:scalpl.util #:scalpl.exchange))

(in-package #:scalpl.mpex)

;;; General Parameters
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +base-stub+ "http://mpex.co/mpex-"))

(defmacro with-request (path form)
  `(multiple-value-bind (stream status)
       (http-request ,(format () "~A~A.php" +base-stub+ path) :want-stream t)
     (with-open-stream (it stream)
       (if (= status 200) ,form
           (values () (format () "HTTP Error ~D~%~A" status
                              (read-line stream)))))))

(defvar *mpex* (make-instance 'exchange :name :mpex))

(defclass mpex-market (market) ((exchange :initform *mpex*)))  ; FIXME is-a → has-a

(defun get-info ()
  (flet ((make-asset (name &optional (d 0))
           (make-instance 'asset :name name :decimals d :exchange *mpex*)))
    (let* ((bitcoin (make-asset "CxBTC" 8)) (assets (list bitcoin)))
      (values (mapcar (lambda (name &aux (asset (make-asset name)))
                        (push asset assets)
                        (make-instance 'mpex-market :primary asset
                                       :counter bitcoin :exchange *mpex*
                                       :decimals 8 :name name))
                      (with-request "mktdepth" (mapcar #'car (read-json it))))
              assets))))

(defmethod fetch-exchange-data ((exchange (eql *mpex*)))
  (with-slots (markets assets) exchange
    (setf (values markets assets) (get-info))))

;;; https://github.com/jurov/MPExAgent
(defclass mpex-agent (gate)
  ((exchange :allocation :class :initform *mpex*)))

(defmethod gate-post ((gate (eql *mpex*)) key secret request
                      &aux (reply-id (sxhash request)))
  (with-open-stream (response
      (http-request key :content-type "text/plain" :method :post
                    :want-stream t :external-format-in :ascii
                    :basic-authorization secret :content
                    (json:encode-json-plist-to-string
                     `("method" ,(car request)
                       "params" ,(apply 'vector (cdr request))
                       "jsonrpc" "2.0" "id" ,reply-id))))
    (json:json-bind (jsonrpc id . #1=(result error)) response
      #.`(progn ,@(mapcar (lambda (ion) `(assert ,@ion))
                          '(((string= "2.0" . #2=(jsonrpc)) #2#
                             "Want jsonrpc \"2.0\", instead: ~S" . #1#)
                            ((if error t (= . #4=(reply-id . #3=(id)))) #3#
                             "Expected id ~A, instead got: ~A" . #4#))))
      (list . #1#))))

;;;
;;; Public Data API
;;;

(defmethod vwap ((market mpex-market) &key (window :30\d))
  (awhen (with-request "vwap" (read-json it))
    (cons-mp market (parse-float (reduce (lambda (x y) (cdr (assoc x y)))
                                         (list :|avg| window (name market))
                                         :from-end t :initial-value it)))))

(defmethod vwap :around ((market market) &rest args &key (mp #'scaled-price))
  (with-slots ((market #1=scalpl.exchange::%market)) market ; dis%usting
    (if (not (ignore-errors (typep market 'mpex-market))) (call-next-method)
        (funcall mp (apply #'vwap market args)))))

(defmethod get-book ((market mpex-market) &key)
  (awhen (with-request "mktdepth" (assoc (name market) (read-json it)))
    (flet ((process (side class predicate)
             (destructuring-bind (token &rest data) (pop it)
               (assert (eq token side))
               (mapcar (lambda (pair)
                         (make-instance class :market market
                                        :price (car pair) :volume (cadr pair)))
                       (reduce (lambda (acc new &aux (prev (car acc)))
                                 (if (eql (car new) (car prev))
                                     (cons (list (car new)
                                                 (+ (cadr prev)
                                                    (cadr new)))
                                           (cdr acc))
                                     (cons new acc)))
                               (sort data predicate :key #'first)
                               :initial-value ())))))
      (pop it) (values (nreverse (process :S 'ask #'<))
                       (nreverse (process :B 'bid #'>))))))

(defun parse-trade (item)
  (destructuring-bind (amount market price)
      (split-sequence #\Space (rss:title item))
    (let* ((price (parse-float price :start 1 :type 'rational))
           (volume (parse-integer (remove #\` amount)))
           (cost (* price volume)))
      (make-instance 'trade :market (find-market market *mpex*) :cost cost
                     :timestamp (parse-rfc1123-timestring (rss:pub-date item))
                     :price price :direction "slold" :volume volume))))

(defun trades-rss ()
  (with-request "rss" (rss:items (rss:parse-rss-stream it))))

(defmethod trades-since ((market mpex-market) &optional since)
  (aprog1 (nreverse (remove-if-not (lambda (trade)
                                     (eq (name (market trade)) (name market)))
                                   (mapcar #'parse-trade (trades-rss))))
    (when since
      (flet ((same-trade (a b)
               (and (timestamp= (timestamp a) (timestamp b))
                    (         =  (volume  a)     (volume b))
                    (         =   (price a)       (price b)))))
        (awhen (member since it :test #'same-trade)
          (return-from trades-since (rest it))))
      (flet ((hms (time) (subseq (princ-to-string (timestamp time)) 11 19)))
        (warn "missing trades: ~A - ~A" (hms since) (hms (first it)))))))

;;;
;;; Private Data API
;;;

(defun parse-placed (statjson)
  (mapcar (lambda (data &aux (oid (parse-integer (string (pop data)))))
            (flet ((value (key) (cdr (assoc key data)))) ; i smell a pattern
              (let ((aksp (string-equal (value :+bs+) "S"))
                    (market (find-market (value :+mpsic+) *mpex*))
                    (volume (value :*quantity)) (price (value :*price)))
                (make-instance 'placed :oid oid :volume volume :market market
                               :given (if aksp (cons-aq (primary market) volume)
                                          (cons-aq (counter market)
                                                   (* price volume)))
                               :price (* price (if aksp 1 -1))))))
          (cdr (assoc :*book statjson))))

(defun parse-balances (statjson &aux funds)
  (flet ((incf-fund (asset amount)
           (incf (getf funds asset 0) amount)))
    (dolist (offer (parse-placed statjson))
      (incf-fund (consumed-asset offer) (quantity (given offer))))
    (dolist (asset-data (cdr (assoc :*holdings statjson)))
      (destructuring-bind (name . amount) asset-data
        (incf-fund (find-asset (if (eq name :*cx-+btc+) "CxBTC"
                                   (string-trim "+" (string name)))
                               *mpex*)
                   amount)))
    (loop for (asset amount) on funds by #'cddr
       collect (cons-aq asset amount))))

(defmethod placed-offers ((gate mpex-agent))
  (awhen (gate-request gate "statjson")  (parse-placed  it)))

(defmethod account-balances ((gate mpex-agent))
  (awhen (gate-request gate "statjson") (parse-balances it)))

;;; All sellers are assesed a 0.2% fee at the moment the sale completes (so if
;;; you sell 500 stocks for 100 satoshi each you get 49`900 satoshi or
;;; 0.000499 BTC). All MKOPT and MKFUT orders are assesed a 2% fee
(defmethod market-fee ((gate mpex-agent) (market market)) '(0 . 0.2))

(defun parse-execution (data)
  (flet ((value (key) (cdr (assoc key data))))  ; i smell a[nother] pattern
    (let* ((direction (value :+bs+)) (volume (value :*quantity))
           (market (find-market (value :+mpsic+) *mpex*))
           (phactor (expt 10 (- (decimals market))))
           (price (* (value :*price) phactor)) (cost (* price volume))
           (timestamp (parse-rfc3339-timestring (value :*date))))
      (make-instance 'execution :market market :direction
                     (format () "~A~:[uy~;ell~]"
                             direction (string= direction "S"))
                     :price price :timestamp timestamp ; TODO: :fee?
                     ;; (sqrt (expt 16 4)) => unhappy birthday
                     :txid (format () "~D~A~D@~D|~D" (value :*track)
                                   direction volume (value :*price)
                                   (timestamp-to-unix timestamp))
                     :volume volume :net-volume volume :cost cost
                     :net-cost (if (string= direction "B") cost
                                   (* (floor (* cost 998/1000) ; yuck
                                             phactor) phactor))))))

;;; The trade and dividend history start with the first transaction after a
;;; point in time one hour previous to the last STAT issued to that user.
(defun raw-executions (gate)
  (cdr (assoc :*trade-history (gate-request gate "statjson"))))

(defmethod execution-since ((gate mpex-agent) market since)
  (awhen (raw-executions gate)          ; spot the twist?
    (let ((parsed (sort (remove market (mapcar #'parse-execution it)
                                :key #'market :test-not #'eq)
                        #'timestamp< :key #'timestamp)))
      (if (null since) parsed
          (member (timestamp since) parsed
                  :key #'timestamp :test #'timestamp<)))))

(defun post-raw-limit (gate type market price volume)
  ;; TODO: optional price & expiry
  (awhen (gate-request gate "neworder" (list type market volume price))
    (flet ((value (key) (cdr (assoc key it))))  ; i smell a pattern
      (cond
        ((string= (value :result) "OK")
         (apply #'values (mapcar #'value '(:order :message :track))))
        ((search "Insufficient funds for this request." (value :message))
         (values () #|(princ `(:unfund ,type ,price ,volume))|#))
        (t (values () (print it)))))))

(defmethod post-offer ((gate mpex-agent) (offer offer)
                       &aux (old (placed-offers gate)))
  (with-slots (market volume price) offer
    (flet ((post (type &aux (dir (if type "B" "S"))) ; TODO: fail loudierly
             (let ((sv (* volume (expt 10 (decimals market)))))
               (awhen (post-raw-limit
                       gate dir (string (name market)) (abs price)
                       (floor (if type (/ sv (abs price)) volume)))
                 (let ((amount (cdr (assoc :amount it))))
                   (dotimes (i 3 (format t "~&LOST ~A ~A" dir offer))
                     (sleep (random (exp 2)))
                     (awhen (find-if (lambda (placed)
                                       (and (= (volume placed) amount)
                                            (= (price  placed) price)))
                                     (set-difference (placed-offers gate) old))
                       (return (change-class offer 'placed :volume amount :oid
                                             (oid it) :given (given it))))))))))
      (post (< price 0)))))

(defmethod cancel-offer ((gate mpex-agent) (offer placed)
                         &aux (oid (oid offer)))
  (awhen (gate-request gate "cancel" (list oid))
    (flet ((value (key) (cdr (assoc key it))))  ; i smell a pattern
      (string-case ((value :result))
        ("OK" t) ("Failed" (not (find oid (placed-offers gate) :key #'oid)))
        (t (values (pprint `(:stuck ,offer)) (value :result) (value :message)))))))
