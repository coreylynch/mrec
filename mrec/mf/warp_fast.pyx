# cython: cdivision=True
# cython: boundscheck=False

cimport numpy as np

cdef extern from "stdlib.h":
    int rand() nogil

cdef extern from "math.h":
    double sqrt(double x) nogil

def warp_sample(np.ndarray[np.float_t,ndim=2] U,
                np.ndarray[np.float_t,ndim=2] V,
                np.ndarray[np.float_t,ndim=1] vals,
                np.ndarray[np.int32_t,ndim=1] indices,
                np.ndarray[np.int32_t,ndim=1] indptr,
                positive_thresh,
                max_trials):
    """
    Sample a user and a violating pair of positive and negative (lower- or un-rated)
    items given the current user and item factors.

    Parameters
    ==========
    U : numpy.ndarray
        User factors.
    V : numpy.ndarray
        Item factors.
    vals : numpy.ndarray
        Rating values.
    indices : numpy.ndarray
        Corresponding item indices.
    indptr : numpy.ndarray
        Corresponding pointers into indices for items for each user,
        so vals,indices,indptr = train.data,train.indices,train.indptr
        assuming train is a scipy.sparse.csr_matrix of ratings.
    positive_thresh: float
        Consider an item to be "positive" i.e. liked if its rating is at least this.
    max_trials : int
        Resample user and positive item if we can't find a violating negative example
        within this many attempts.

    Returns
    =======
    u : int
        Sampled user.
    i : int
        Sampled positive item.
    j : int
        Sampled negative item.
    N : int
        Number of negative items that had to be sampled to find a violating one.
    tot_trials : int
        Total number of trials taken to find a sample.
    """

    cdef unsigned int num_users, u, ix, i, N, tot_trials
    cdef int j

    num_users = U.shape[0]
    tot_trials = 0

    while True:
        u,ix,i = sample_positive_example(positive_thresh,num_users,vals,indices,indptr)
        j,N = sample_violating_negative_example(U,V,vals,indices,indptr[u],indptr[u+1],u,ix,i,max_trials)
        tot_trials += N
        if j >= 0:
            return u,i,j,N,tot_trials

cpdef sample_violating_negative_example(np.ndarray[np.float_t,ndim=2] U,
                                        np.ndarray[np.float_t,ndim=2] V,
                                        np.ndarray[np.float_t,ndim=1] vals,
                                        np.ndarray[np.int32_t,ndim=1] indices,
                                        begin,
                                        end,
                                        u,
                                        ix,
                                        i,
                                        max_trials):
    """
    Sample a violating negative item given the current item and user factors.

    Parameters
    ==========
    U : numpy.ndarray
        User factors.
    V : numpy.ndarray
        Item factors.
    vals : numpy.ndarray
        Rating values.
    indices : numpy.ndarray
        Corresponding item indices.
    begin : int
        Start index into vals and indices for possible negative item.
    end : int
        End index into vals and inidices for possible negative item.
    u : int
        The sample user.
    ix : int
        Index into vals and indices for the positive item.
    i : int
        The sample positive item.
    max_trials : int
        Give up if we can't find a violating example within this many attempts.

    Returns
    =======
    j : int
        Sampled negative item or -1 if no violating item could be found.
    N : int
        Number of negative items that had to be sampled to find a violating one.
    """

    cdef float r
    cdef unsigned int N, num_items
    cdef int j

    num_items = V.shape[0]

    r = U[u].dot(V[i])
    for N in xrange(1,max_trials):
        # find j!=i s.t. data[u,j] < data[u,i]
        j = sample_negative_example(num_items,vals,indices,begin,end,ix)
        if r - U[u].dot(V[j]) < 1:
            # found a violating pair
            return j,N
    # no violating pair found after max_trials, give up
    return -1,max_trials

cdef sample_negative_example(num_items,
                             np.ndarray[np.float_t,ndim=1] vals,
                             np.ndarray[np.int32_t,ndim=1] indices,
                             begin,
                             end,
                             ix):
    """
    Sample a negative (lower- or un-rated) item given a positive item.

    Parameters
    ==========
    num_items : int
        Total number of items.
    vals : numpy.ndarray
        Rating values.
    indices : numpy.ndarray
        Corresponding item indices.
    begin : int
        Start index into vals and indices for possible negative item.
    end : int
        End index into vals and inidices for possible negative item.
    ix : int
        Index into vals and indices for the positive item.

    Returns
    =======
    j : int
        Sampled negative item.
    """

    cdef unsigned int j, jx, found

    while True:
        # sample item uniformly with replacement
        j = rand() % num_items
        found = 0
        for jx in xrange(begin,end):
            if indices[jx] == j:
                found = 1
                break
        if not found or vals[jx] < vals[ix]:
            return j

cpdef sample_positive_example(positive_thresh,
                              num_users,
                              np.ndarray[np.float_t,ndim=1] vals,
                              np.ndarray[np.int32_t,ndim=1] indices,
                              np.ndarray[np.int32_t,ndim=1] indptr):
    """
    Uniformly sample a user and one of their positive items.
    Note this doesn't really sample users uniformly: they will
    get sampled more often if they have a high proportion of
    positive items.

    Parameters
    ==========
    positive_thresh: float
        Consider an item to be "positive" i.e. liked if its rating is at least this.
    num_users : int
        The total number of users.
    vals : numpy.ndarray
        Rating values.
    indices : numpy.ndarray
        Corresponding item indices.
    indptr : numpy.ndarray
        Corresponding pointers into indices for items for each user,
        so vals,indices,indptr = train.data,train.indices,train.indptr
        assuming train is a scipy.sparse.csr_matrix of ratings.
    """

    cdef unsigned int u, i, ix, begin, end

    while True:
        # pick a random user
        u = rand() % num_users
        begin = indptr[u]
        end = indptr[u+1]
        if end > begin:
            # pick one of their positive items
            ix = begin + (rand() % (end-begin))
            if vals[ix] >= positive_thresh:
                i = indices[ix]
                return u,ix,i

def apply_updates(np.ndarray[np.float_t,ndim=2] F,
                  np.ndarray[np.int32_t,ndim=1] rows,
                  np.ndarray[np.float_t,ndim=2] deltas,
                  gamma,
                  C):
    """
    Apply SGD updates.

    Parameters
    ==========
    F : numpy.ndarray
        The factors to be updated.
    rows : numpy.ndarray
        Vector of row indices for which we have updates.
    deltas : numpy.ndarray
        Matrix of updates.
    gamma : float
        The learning rate.
    C : float
        The regularization constant.
    """
 
    cdef unsigned int i, num
    cdef float p

    assert(rows.shape[0] == deltas.shape[0])

    num = rows.shape[0]
    for i in xrange(num):
        row = rows[i]
        delta = deltas[i]
        F[row] += gamma*delta
        p = sqrt(F[row].T.dot(F[row]))/C
        if p > 1:
            F[row] /= p  # ensure ||F[row]|| <= C
